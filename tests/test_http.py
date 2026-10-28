"""HTTP framing, authentication and cancellation isolation without GPU inference."""
import asyncio
import json
import threading
import time
import unittest
from aiohttp import ClientTimeout
from aiohttp.test_utils import TestClient, TestServer
from insane_qwen.server import make_app, MODELS


class FakeEngine:
    def __init__(self):
        self.lock = asyncio.Lock(); self.waiting = 0
        self.active = 0; self.peak = 0; self.cancelled = 0
        self.guard = threading.Lock()
    def prepare(self, body): return None, {}
    def generate(self, body, ids, generation, stop, emit):
        with self.guard:
            self.active += 1; self.peak = max(self.peak, self.active)
        try:
            for _ in range(8):
                if stop.is_set():
                    self.cancelled += 1
                    # Simulate hook cleanup that must finish before the next request.
                    time.sleep(0.04)
                    return
                emit("text", "hello "); time.sleep(0.01)
            emit("result", {"choices": [{"index": 0, "message": {"role": "assistant", "content": "hello"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3}})
        finally:
            with self.guard: self.active -= 1
            emit("end", None)


class HTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = FakeEngine()
        self.client = TestClient(TestServer(make_app(self.engine, "test-only-key"), handler_cancellation=True), timeout=ClientTimeout(total=10))
        await self.client.start_server()
    async def asyncTearDown(self): await self.client.close()
    def headers(self): return {"Authorization": "Bearer test-only-key"}
    async def test_auth_and_model_discovery(self):
        self.assertEqual((await self.client.get('/v1/models')).status, 401)
        response = await self.client.get('/v1/models', headers=self.headers())
        self.assertEqual([m['id'] for m in (await response.json())['data']], list(MODELS))
    async def test_stream_has_usage_finish_and_done(self):
        response = await self.client.post('/v1/chat/completions', headers=self.headers(), json={'model': MODELS[0], 'stream': True})
        text = await response.text()
        frames = [line[6:] for line in text.splitlines() if line.startswith('data: ')]
        self.assertEqual(frames[-1], '[DONE]')
        last = json.loads(frames[-2])
        self.assertEqual(last['choices'][0]['finish_reason'], 'stop')
        self.assertEqual(last['usage']['total_tokens'], 3)
    async def test_cancellation_keeps_models_serialized_until_cleanup(self):
        first = await self.client.post('/v1/chat/completions', headers=self.headers(), json={'model': MODELS[1], 'stream': True})
        await first.content.readline(); first.close()
        second = await self.client.post('/v1/chat/completions', headers=self.headers(), json={'model': MODELS[0]})
        self.assertEqual(second.status, 200)
        await second.json()
        self.assertEqual(self.engine.peak, 1)
        self.assertEqual(self.engine.cancelled, 1)
        self.assertEqual(self.engine.waiting, 0)


if __name__ == '__main__': unittest.main(verbosity=2)
