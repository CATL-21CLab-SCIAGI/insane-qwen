import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        folder = Path(self.tmp.name)
        self.old = os.environ.get('INSANE_QWEN_STATE')
        os.environ['INSANE_QWEN_STATE'] = str(folder)
        (folder/'key.json').write_text(json.dumps({'backend_api_key':'unit-test-backend'}))
        self.forwarded = None
        async def completion(request):
            self.assertEqual(request.headers['Authorization'], 'Bearer unit-test-backend')
            self.forwarded = await request.json()
            return web.json_response({'choices':[{'message':{'content':'test'},'finish_reason':'stop'}]})
        backend = web.Application(); backend.router.add_post('/v1/chat/completions', completion)
        self.backend = TestServer(backend); await self.backend.start_server()
        (folder/'gateway.json').write_text(json.dumps({'secrets':str(folder/'key.json'),
            'tailscale_login':'owner@example.test','origins':['https://private.example.test'],
            'backends':{'qwen35-4b-steered':str(self.backend.make_url('')).rstrip('/')},
            'images':{},'sandbox_pools':[]}))
        sys.modules.pop('insane_qwen.gateway', None)
        self.gateway = importlib.import_module('insane_qwen.gateway')
        app = web.Application(middlewares=[self.gateway.auth]); self.gateway.routes(app)
        app.on_startup.append(self.gateway.start); app.on_cleanup.append(self.gateway.stop)
        self.client = TestClient(TestServer(app)); await self.client.start_server()
    async def asyncTearDown(self):
        await self.client.close(); await self.backend.close(); self.tmp.cleanup()
        if self.old is None: os.environ.pop('INSANE_QWEN_STATE', None)
        else: os.environ['INSANE_QWEN_STATE'] = self.old
    async def test_identity_origin_and_handle_forwarding(self):
        self.assertEqual((await self.client.get('/v1/models')).status,401)
        headers = {'Tailscale-User-Login':'owner@example.test','Origin':'https://evil.example.test'}
        body = {'model':'qwen35-4b-steered','messages':[{'role':'user','content':'hello'}],
            'steering':{'layer':20,'neuron':8888,'intensity':.6}}
        self.assertEqual((await self.client.post('/v1/chat/completions',headers=headers,json=body)).status,403)
        headers['Origin'] = 'https://private.example.test'
        response = await self.client.post('/v1/chat/completions',headers=headers,json=body)
        self.assertEqual(response.status,200); await response.read()
        self.assertEqual(self.forwarded,body)
        self.assertEqual((await self.client.get('/images',headers=headers)).status,200)
    async def test_static_ui_contains_default_and_no_scanner_route(self):
        response = await self.client.get('/')
        self.assertIn('Content-Security-Policy',response.headers)
        html = await response.text(); self.assertIn('value="8888"',html); self.assertIn('value="0.6"',html)
        self.assertEqual((await self.client.post('/scan',headers={'Tailscale-User-Login':'owner@example.test'},json={})).status,404)

if __name__ == '__main__': unittest.main()
