"""Private OpenAI-compatible, serialized original/steered Qwen3.5-4B service."""
import argparse
import asyncio
import copy
from contextlib import nullcontext
import hmac
import json
import threading
import time
import uuid
from pathlib import Path

import torch
from aiohttp import web
from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration, TextStreamer, StoppingCriteria
from .steering import Steering, handles, DEFAULT, LYRA
from .kernels import enable_fla

MODELS = ("qwen35-4b-native", "qwen35-4b-steered")
MAX_CONTEXT = 32768


class Stop(StoppingCriteria):
    def __init__(self, event): self.event = event
    def __call__(self, *args, **kwargs): return self.event.is_set()


class Streamer(TextStreamer):
    def __init__(self, tokenizer, emit):
        super().__init__(tokenizer, skip_prompt=True, skip_special_tokens=True)
        self.emit = emit
    def on_finalized_text(self, text, stream_end=False):
        if text: self.emit("text", text)


class Engine:
    def __init__(self, path, calibration=None):
        torch.cuda.set_per_process_memory_fraction(0.25)
        self.tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True)
        self.model = Qwen3_5ForConditionalGeneration.from_pretrained(
            path, dtype=torch.bfloat16, device_map="cuda:0", local_files_only=True,
            attn_implementation="sdpa").eval()
        calibration = Path(calibration) if calibration else Path(__file__).with_name('calibration.json')
        self.steering = Steering(self.model.model.language_model.layers,
                                 json.loads(calibration.read_text())['residual_medians'])
        self.lock = asyncio.Lock()
        self.waiting = 0

    def prepare(self, body):
        if not isinstance(body, dict): raise ValueError("Request must be a JSON object")
        if body.get("model") not in MODELS: raise ValueError("Unknown model")
        handles(body.get("steering"))
        messages = body.get("messages")
        if not isinstance(messages, list) or not messages: raise ValueError("messages must be a nonempty list")
        if any(not isinstance(m, dict) or not isinstance(m.get("content", ""), (str, type(None))) for m in messages):
            raise ValueError("This endpoint supports text messages only")
        if body.get("n", 1) != 1: raise ValueError("Only n=1 is supported")
        if body.get("stop"): raise ValueError("Custom stop strings are not supported")
        if body.get("tools") and body.get("stream"): raise ValueError("Tool calls require stream=false")
        if type(body.get("seed", 42)) is not int or not 0 <= body.get("seed", 42) < 2**63:
            raise ValueError("seed must be an integer in 0..2^63-1")
        temperature = float(body.get("temperature", 0.7))
        top_p = float(body.get("top_p", 0.8))
        top_k = int(body.get("top_k", 20))
        count = int(body.get("max_tokens", body.get("max_completion_tokens", 1024)))
        if not (0 <= temperature <= 2 and 0 < top_p <= 1 and -1 <= top_k <= 1000 and 1 <= count <= 8192):
            raise ValueError("Invalid sampling parameters (max_tokens: 1..8192)")
        # OpenAI transports tool arguments as JSON strings; Qwen's HF template
        # expects mappings when rendering an assistant tool-call history.
        template_messages = copy.deepcopy(messages)
        for message in template_messages:
            for call in message.get("tool_calls") or []:
                function = call["function"]
                if isinstance(function.get("arguments"), str):
                    function["arguments"] = json.loads(function["arguments"])
                if not isinstance(function.get("arguments"), dict):
                    raise ValueError("Tool arguments must encode an object")
        ids = self.tokenizer.apply_chat_template(template_messages, tools=body.get("tools"), tokenize=True,
            add_generation_prompt=True, enable_thinking=False, return_tensors="pt", return_dict=False)
        if ids.shape[-1] + count > MAX_CONTEXT:
            raise ValueError(f"Prompt plus max_tokens exceeds {MAX_CONTEXT} tokens; start a new chat")
        return ids, dict(max_new_tokens=count, do_sample=temperature > 0,
            **({"temperature": temperature, "top_p": top_p, "top_k": max(0, top_k)} if temperature > 0 else {}))

    def generate(self, body, ids, generation, stop, emit):
        try:
            with torch.inference_mode():
                torch.manual_seed(body.get("seed", 42))
                if stop.is_set(): return
                ids = ids.to("cuda:0")
                mask = torch.ones_like(ids)
                amplitudes = []
                if body["model"] == MODELS[1]:
                    amplitudes = self.steering.prepare(handles(body.get("steering")), lambda: self.model(
                        input_ids=ids, attention_mask=mask, use_cache=False, logits_to_keep=1))
                context = self.steering.apply(amplitudes) if amplitudes else nullcontext()
                with context:
                    output = self.model.generate(input_ids=ids, attention_mask=mask,
                        streamer=Streamer(self.tokenizer, emit) if body.get("stream") else None,
                        stopping_criteria=[Stop(stop)], **generation)
                tokens = output[0, ids.shape[-1]:]
                answer = self.tokenizer.decode(tokens, skip_special_tokens=True)
                message = {"role": "assistant", "content": answer}
                finish = "length" if len(tokens) == generation["max_new_tokens"] else "stop"
                if body.get("tools"):
                    from vllm.tool_parsers import ToolParserManager
                    from vllm.entrypoints.openai.chat_completion.protocol import ChatCompletionRequest
                    tool_request = ChatCompletionRequest(model=body["model"], messages=body["messages"], tools=body["tools"])
                    parsed = ToolParserManager.get_tool_parser("qwen3_coder")(self.tokenizer, tools=tool_request.tools).extract_tool_calls(answer, tool_request)
                    if parsed.tools_called:
                        message["content"] = parsed.content or ""
                        message["tool_calls"] = [c.model_dump() for c in parsed.tool_calls]
                        finish = "tool_calls"
                emit("result", {"choices": [{"index": 0, "message": message, "finish_reason": finish}],
                    "usage": {"prompt_tokens": ids.shape[-1], "completion_tokens": len(tokens), "total_tokens": output.shape[-1]},
                    "steering": {"active": bool(amplitudes), "amplitudes": {f"L{h.layer}N{h.neuron}": float(a) for h,a in amplitudes}}})
        except Exception as error:
            # No request, prompt, credential, or model output in logs/errors.
            print(f"generation failed: {type(error).__name__}", flush=True)
            emit("error", {"error": {"message": f"Generation failed ({type(error).__name__})", "type": "server_error"}})
        finally:
            emit("end", None)


def make_app(engine, key):
    @web.middleware
    async def auth(request, handler):
        supplied = request.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(supplied, ("Bearer " + key).encode()):
            return web.json_response({"error": "unauthorized"}, status=401)
        return await handler(request)
    app = web.Application(middlewares=[auth], client_max_size=1 << 20)

    async def models(request):
        return web.json_response({"object": "list", "data": [{"id": m, "object": "model"} for m in MODELS]})

    async def health(request):
        return web.json_response({"ok": True, "models": list(MODELS), "waiting": engine.waiting,
            "max_context": MAX_CONTEXT, "default": DEFAULT, "presets": {"lyra": LYRA}, "indexing": "zero-based", "calibration": "fixed four-context reference; optional per-prompt tokens 1:",
            "application": "additive down_proj input; all prefill/decode positions"})

    async def chat(request):
        if engine.waiting >= 4: return web.json_response({"error": "queue full"}, status=429)
        try:
            body = await request.json()
            ids, generation = engine.prepare(body)
        except (ValueError, TypeError, KeyError) as error:
            return web.json_response({"error": str(error)}, status=400)
        engine.waiting += 1
        stop = threading.Event()
        worker = None
        acquired = False
        try:
            await engine.lock.acquire()
            acquired = True
            if request.transport is None or request.transport.is_closing():
                raise ConnectionResetError()
            loop, queue = asyncio.get_running_loop(), asyncio.Queue()
            def emit(kind, data): loop.call_soon_threadsafe(queue.put_nowait, (kind, data))
            worker = threading.Thread(target=engine.generate, args=(body, ids, generation, stop, emit), daemon=True)
            worker.start()
            meta = {"id": "chatcmpl-" + uuid.uuid4().hex, "created": int(time.time()), "model": body["model"]}
            stream = None
            if body.get("stream"):
                stream = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
                await stream.prepare(request)
            result, error = None, None
            while True:
                try: kind, data = await asyncio.wait_for(queue.get(), timeout=5)
                except asyncio.TimeoutError:
                    if request.transport is None or request.transport.is_closing(): raise ConnectionResetError()
                    if stream: await stream.write(b": keepalive\n\n")
                    continue
                if kind == "end": break
                if kind == "error": error = data
                elif kind == "result": result = data
                elif kind == "text" and stream:
                    chunk = {**meta, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": data}, "finish_reason": None}]}
                    await stream.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            if error or result is None:
                error = error or {"error": {"message": "Generation cancelled"}}
                if stream:
                    await stream.write(("data: " + json.dumps(error) + "\n\n").encode())
                    await stream.write_eof()
                    return stream
                return web.json_response(error, status=500)
            if stream:
                chunk = {**meta, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": result["choices"][0]["finish_reason"]}], "usage": result["usage"]}
                await stream.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())
                await stream.write_eof()
                return stream
            return web.json_response({**meta, "object": "chat.completion", **result})
        finally:
            stop.set()
            # Never release serialization while the GPU worker still has hooks installed.
            if worker is not None and worker.is_alive():
                await asyncio.shield(asyncio.to_thread(worker.join))
            if acquired: engine.lock.release()
            engine.waiting -= 1

    app.router.add_get("/v1/models", models)
    app.router.add_get("/health", health)
    app.router.add_post("/v1/chat/completions", chat)
    return app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--secrets", required=True)
    parser.add_argument("--calibration")
    parser.add_argument("--fla", action="store_true")
    parser.add_argument("--smoke-report")
    args = parser.parse_args()
    key = json.loads(Path(args.secrets).read_text())["backend_api_key"]
    if args.fla: enable_fla()
    engine = Engine(args.model, args.calibration)
    if args.smoke_report:
        reports = []
        for model in (MODELS[0], MODELS[1], MODELS[0]):
            body = {"model": model, "messages": [{"role": "user", "content": "I finally finished a difficult project. Reply in one short sentence."}], "temperature": 0, "max_tokens": 48}
            ids, generation = engine.prepare(body)
            result = {}
            def save(kind, data):
                if kind in ("result", "error"): result.update(data)
            engine.generate(body, ids, generation, threading.Event(), save)
            if "error" in result: raise RuntimeError(str(result["error"]))
            reports.append({"model": model, **result})
        assert reports[0]["choices"] == reports[2]["choices"], "Original output changed after steering"
        Path(args.smoke_report).write_text(json.dumps({"baseline_restored": True, "runs": reports, "torch": torch.__version__}, indent=2))
    print("READY: Qwen3.5-4B original/steered, shared weights, serialized requests", flush=True)
    web.run_app(make_app(engine, key), host=args.host, port=args.port, access_log=None, handler_cancellation=True)


if __name__ == "__main__": main()
