"""Private Tailscale gateway: chat, sandbox agents, history and static UI."""
import asyncio
import hashlib
import hmac
import json
import os
import shlex
import time
import uuid
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, web

P = Path(os.environ.get('INSANE_QWEN_STATE', 'state')).resolve()
CONFIG = json.loads((P / 'gateway.json').read_text())
SECRETS = Path(CONFIG['secrets'])
POOLS = [Path(p) for p in CONFIG.get('sandbox_pools', [])]
STATIC = Path(__file__).with_name('web')
WEB = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'), '/app.css': ('app.css', 'text/css')}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; "
       "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
MAX_SANDBOXES, MAX_LIFETIME, MAX_EXEC_TIMEOUT, MAX_STEPS, MAX_COMMAND = 4, 3600, 300, 300, 64 * 1024
HARNESS = {
    'source': 'insane-qwen bash agent',
    'system_prompt': ('You are an agent, your current working directory is {cwd}.\n\n'
                      'You can use the tools available to you to interact with the computer to assist the user '
                      'in completing tasks.'),
    'training_user_prefix': 'Fix the following issue:\n\n',
    'tools': [{'type': 'function', 'function': {'name': 'bash', 'description': 'Execute a noninteractive bash command in the offline sandbox. Each call starts a new shell. timeout is seconds, default 60, maximum 300.', 'parameters': {'type': 'object', 'properties': {'command': {'type': 'string'}, 'timeout': {'type': 'integer'}}, 'required': ['command']}}}],
    'sampling': {'temperature': 1.0, 'top_p': 1.0, 'top_k': -1, 'max_tokens': 8192,
                 'chat_template_kwargs': {'enable_thinking': False}},
    'limits': {'step_limit': 300, 'max_observation_chars': 12000, 'context_tokens': 262144,
               'exec_timeout_default': 60, 'exec_timeout_max': 300},
    'observation_format': "truncate_middle(output, 12000) + \"\\n\\nTool metadata: {'returncode': N}\"",
}


def secrets():
    return json.loads(SECRETS.read_text())


def backends():
    return CONFIG['backends']


def images():
    return CONFIG.get('images', {})


def affinity_order(image, servers):  # same order as archlab.training.dlc_sandbox._affinity_order (source-v7)
    return sorted(servers, key=lambda s: hashlib.sha256(f"{image}\0{s}".encode()).digest(), reverse=True)


@web.middleware
async def auth(request, handler):
    if request.method == 'GET' and request.path in WEB:
        name, kind = WEB[request.path]
        return web.Response(body=(STATIC / name).read_bytes(), content_type=kind, headers={
            'Content-Security-Policy': CSP, 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
            'Cache-Control': 'no-cache'})
    # Serve strips client-supplied identity headers and adds its own. Trust them
    # only on this localhost-only listener, and only for the configured owner.
    owner = CONFIG['tailscale_login']
    identity_ok = (request.remote in ('127.0.0.1', '::1') and
                   request.headers.get('Tailscale-User-Login') == owner)
    supplied = request.headers.get('Authorization', '')
    bearer_ok = bool(supplied) and hmac.compare_digest(
        supplied.encode(), ('Bearer ' + secrets().get('gateway_token', '')).encode())
    if not identity_ok and not bearer_ok:
        return web.json_response({'error': 'unauthorized'}, status=401)
    # Tokenless browser requests must not permit cross-origin form/JSON posts.
    if request.method not in ('GET', 'HEAD', 'OPTIONS'):
        origin = request.headers.get('Origin')
        allowed = set(CONFIG['origins'])
        if origin is not None and origin not in allowed:
            return web.json_response({'error': 'cross-origin request denied'}, status=403)
        if request.content_type != 'application/json':
            return web.json_response({'error': 'application/json required'}, status=415)
    return await handler(request)


class Sandboxes:
    """At most MAX_SANDBOXES live pool sandboxes, each with a bounded lifetime; all removed on shutdown."""

    def __init__(self, http):
        self.http, self.live = http, {}  # id -> {'url', 'image', 'cwd', 'deadline'}

    async def create(self, key):
        spec = images().get(key)
        if spec is None:
            raise web.HTTPBadRequest(text='image not in the allowlist (GET /images)')
        if len(self.live) >= MAX_SANDBOXES:
            raise web.HTTPTooManyRequests(text=f'at most {MAX_SANDBOXES} live sandboxes')
        body = {'image': spec['image'], 'lifetime': MAX_LIFETIME}
        servers = [s for pool in POOLS for s in affinity_order(
            spec['image'], [json.loads(p.read_text())['url'] for p in pool.glob('*.json')])]
        for server in servers:
            try:
                async with self.http.post(f'{server}/sandboxes', json=body, timeout=ClientTimeout(total=900)) as r:
                    if r.status == 200:
                        box = f"{server}/sandboxes/{(await r.json())['id']}"
                        sid = uuid.uuid4().hex[:12]
                        self.live[sid] = {'url': box, 'image': key, 'cwd': spec['cwd'], 'env': ''.join(
                            f'export {k}={shlex.quote(v)}; ' for k, v in spec.get('env', {}).items()),
                                          'deadline': time.time() + MAX_LIFETIME}
                        return sid
            except (OSError, asyncio.TimeoutError):
                continue
        raise web.HTTPServiceUnavailable(text='sandbox pool full; retry shortly')

    async def execute(self, sid, command, timeout=60):
        box = self.live.get(sid)
        if box is None:
            raise web.HTTPNotFound(text='unknown sandbox')
        timeout = max(1, min(int(timeout or 60), MAX_EXEC_TIMEOUT))
        body = {'command': box['env'] + str(command)[:MAX_COMMAND], 'cwd': box['cwd'], 'timeout': timeout}
        async with self.http.post(f"{box['url']}/exec", json=body, timeout=ClientTimeout(total=timeout + 60)) as r:
            if r.status != 200:
                raise web.HTTPBadGateway(text=f'sandbox exec failed: {r.status}')
            return await r.json()

    async def delete(self, sid):
        box = self.live.pop(sid, None)
        if box:
            try:
                async with self.http.delete(box['url'], timeout=ClientTimeout(total=30)):
                    pass
            except (OSError, asyncio.TimeoutError):
                pass

    async def reaper(self):
        while True:
            for sid in [s for s, b in self.live.items() if b['deadline'] < time.time()]:
                await self.delete(sid)
            await asyncio.sleep(30)


def truncate_middle(text, limit):
    if len(text) <= limit: return text
    half = limit // 2
    return (f'[TRUNCATED: {len(text) - limit} characters omitted; narrow the command to inspect them.]\n'
            + text[:half] + '\n[...OUTPUT OMITTED...]\n' + text[-(limit - half):])


def observation(result):
    return truncate_middle(result.get('output', '') or '', 12000) + \
        f"\n\nTool metadata: {{'returncode': {result.get('returncode')}}}"


async def chat(http, model, messages, extra=None):
    url = backends().get(model)
    if url is None:
        raise web.HTTPBadRequest(text=f'unknown model {model!r}')
    body = {'model': model, 'messages': messages, 'tools': HARNESS['tools'], **HARNESS['sampling'], **(extra or {})}
    headers = {'Authorization': f"Bearer {secrets()['backend_api_key']}"}
    async with http.post(f'{url}/v1/chat/completions', json=body, headers=headers,
                         timeout=ClientTimeout(total=1800)) as r:
        reply = await r.json()
        if r.status != 200:
            raise web.HTTPBadGateway(text=json.dumps(reply)[:500])
        return reply


def routes(app):
    r = web.RouteTableDef()

    @r.get('/healthz')
    async def healthz(_):
        return web.json_response({'ok': True, 'models': list(backends()), 'sandboxes': len(app['boxes'].live)})

    @r.get('/harness')
    async def harness(_):
        return web.json_response(HARNESS)

    @r.get('/images')
    async def image_list(_):
        return web.json_response({k: {x: v[x] for x in ('cwd', 'repo', 'note') if x in v} for k, v in images().items()})

    @r.get('/v1/models')
    async def models(_):
        return web.json_response({'object': 'list', 'data': [{'id': m, 'object': 'model'} for m in backends()]})

    @r.post('/v1/chat/completions')
    async def completions(request):
        body = await request.json()
        url = backends().get(body.get('model'))
        if url is None:
            return web.json_response({'error': 'unknown model'}, status=400)
        headers = {'Authorization': f"Bearer {secrets()['backend_api_key']}", 'Content-Type': 'application/json'}
        async with app['http'].post(f'{url}/v1/chat/completions', json=body, headers=headers,
                                    timeout=ClientTimeout(total=1800)) as upstream:
            response = web.StreamResponse(status=upstream.status, headers={
                'Content-Type': upstream.headers.get('Content-Type', 'application/json')})
            await response.prepare(request)
            async for chunk in upstream.content.iter_any():
                await response.write(chunk)
            await response.write_eof()
            return response

    @r.post('/sandboxes')
    async def create(request):
        body = await request.json()
        return web.json_response({'id': await app['boxes'].create(body.get('image'))})

    @r.post('/sandboxes/{sid}/exec')
    async def execute(request):
        body = await request.json()
        result = await app['boxes'].execute(request.match_info['sid'], body.get('command', ''), body.get('timeout'))
        return web.json_response({**result, 'observation': observation(result)})

    @r.delete('/sandboxes/{sid}')
    async def delete(request):
        await app['boxes'].delete(request.match_info['sid'])
        return web.json_response({'deleted': True})

    @r.get('/agent/runs')
    async def runs(_):
        return web.json_response(sorted(p.stem for p in (P / 'runs').glob('*.json')))

    @r.get('/agent/runs/{rid}')
    async def run_get(request):
        path = P / 'runs' / f"{request.match_info['rid']}.json"
        if not path.is_file() or '/' in request.match_info['rid']:
            return web.json_response({'error': 'unknown run'}, status=404)
        return web.json_response(json.loads(path.read_text()))

    @r.post('/agent/runs')
    async def run(request):
        """Training-faithful bash agent loop; streams one SSE event per message."""
        body = await request.json()
        model, task, key = body.get('model'), str(body.get('task', ''))[:32768], body.get('image')
        steps = max(1, min(int(body.get('max_steps', 100)), MAX_STEPS))
        extra = {'steering': body['steering']} if 'steering' in body else {}
        rid = time.strftime('%Y%m%dT%H%M%S-') + uuid.uuid4().hex[:6]
        sid = await app['boxes'].create(key)
        cwd = app['boxes'].live[sid]['cwd']
        messages = [{'role': 'system', 'content': HARNESS['system_prompt'].format(cwd=cwd)},
                    {'role': 'user', 'content': task}]
        record = {'id': rid, 'model': model, 'image': key, 'max_steps': steps, 'messages': messages,
                  'steering': extra.get('steering'), 'harness': HARNESS['source'], 'started': time.time(), 'status': 'running'}
        stream = web.StreamResponse(headers={'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache'})
        await stream.prepare(request)

        async def emit(kind, payload):
            await stream.write(f'event: {kind}\ndata: {json.dumps(payload)}\n\n'.encode())

        try:
            await emit('run', {'id': rid, 'model': model, 'image': key, 'cwd': cwd})
            for step in range(steps):
                reply = await chat(app['http'], model, messages, extra)
                message = reply['choices'][0]['message']
                assistant = {'role': 'assistant', 'content': message.get('content') or ''}
                calls = message.get('tool_calls') or []
                if calls:
                    assistant['tool_calls'] = calls
                messages.append(assistant)
                await emit('assistant', {'step': step, **assistant, 'usage': reply.get('usage'),
                                         'finish_reason': reply['choices'][0].get('finish_reason')})
                if not calls:
                    record['status'] = 'finished'
                    break
                for call in calls:
                    fn = call.get('function', {})
                    try:
                        args = json.loads(fn.get('arguments') or '{}')
                        result = await app['boxes'].execute(sid, args.get('command', ''), args.get('timeout'))
                        content = observation(result)
                    except (ValueError, AttributeError) as error:
                        content = f'Tool call error: {error}'
                    tool = {'role': 'tool', 'tool_call_id': call.get('id'), 'name': fn.get('name'),
                            'content': content}
                    messages.append(tool)
                    await emit('tool', {'step': step, **tool})
            else:
                record['status'] = 'step_limit'
        except (ConnectionResetError, asyncio.CancelledError):
            record['status'] = 'client_disconnected'
            raise
        except web.HTTPException as error:
            record['status'] = f'error: {error.text}'
            await emit('error', {'error': error.text})
        finally:
            await app['boxes'].delete(sid)
            record['finished'] = time.time()
            (P / 'runs').mkdir(exist_ok=True)
            (P / 'runs' / f'{rid}.json').write_text(json.dumps(record, indent=1))
        await emit('done', {'id': rid, 'status': record['status'], 'messages': len(messages)})
        return stream

    app.add_routes(r)


async def start(app):
    app['http'] = ClientSession(trust_env=False)  # never route pool/backend calls through an HTTP proxy
    app['boxes'] = Sandboxes(app['http'])
    app['reaper'] = asyncio.create_task(app['boxes'].reaper())


async def stop(app):
    app['reaper'].cancel()
    for sid in list(app['boxes'].live):
        await app['boxes'].delete(sid)
    await app['http'].close()


def main():
    app = web.Application(middlewares=[auth], client_max_size=1 << 20)
    routes(app)
    app.on_startup.append(start)
    app.on_cleanup.append(stop)
    web.run_app(app, host='127.0.0.1', port=int(os.environ.get('INSANE_QWEN_PORT', '18090')), access_log=None)


if __name__ == '__main__':
    main()
