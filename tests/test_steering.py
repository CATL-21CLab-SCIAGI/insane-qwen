import unittest
import torch
from insane_qwen.steering import Handle, Steering, handles


class Layer(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.mlp = torch.nn.Module()
        self.mlp.down_proj = torch.nn.Linear(3, 2, bias=False)
        with torch.no_grad(): self.mlp.down_proj.weight.copy_(torch.tensor([[1., 2., 0.], [0., 0., 1.]]))
    def forward(self, x): return self.mlp.down_proj(x)


class SteeringTests(unittest.TestCase):
    def test_validation(self):
        self.assertEqual(handles()[0], Handle())
        for value in [{'layer': True}, {'neuron': -1}, {'layer': 32}, {'intensity': float('nan')},
                      {'operation': 'unknown'}, {'extra': 1}, {'intensity': 5}, []]:
            with self.subTest(value=value), self.assertRaises(ValueError): handles(value)
        with self.assertRaises(ValueError): handles([{}, {}])

    def test_add_multiply_and_cleanup(self):
        layer = Layer(); steering = Steering([layer], {0: 4.})
        x = torch.tensor([[[1., 3., 2.], [2., -1., 1.]]]); baseline = layer(x).clone()
        add = steering.prepare([Handle(0, 1, intensity=.5)], lambda: None)
        with steering.apply(add): self.assertTrue(torch.equal(layer(x), baseline + torch.tensor([2., 0.])))
        self.assertTrue(torch.equal(layer(x), baseline))
        mul = steering.prepare([Handle(0, 1, operation='multiply', intensity=-1)], lambda: None)
        with self.assertRaises(RuntimeError):
            with steering.apply(mul):
                changed = x.clone(); changed[..., 1] *= -1
                self.assertTrue(torch.equal(layer(x), torch.nn.functional.linear(changed, layer.mlp.down_proj.weight)))
                raise RuntimeError('interrupt')
        self.assertTrue(torch.equal(layer(x), baseline))
        self.assertFalse(layer.mlp.down_proj._forward_pre_hooks)

    def test_prompt_calibration_excludes_first_token_and_removes_hooks(self):
        layer = Layer(); steering = Steering([layer], {0: 99.})
        x = torch.tensor([[[999., 0., 0.], [3., 0., 4.], [0., 0., 8.]]])
        values = steering.prepare([Handle(0, 1, intensity=.6, calibration='prompt')], lambda: layer(x))
        self.assertAlmostEqual(float(values[0][1]), 1.5)
        self.assertFalse(layer._forward_hooks)
        def fail(): raise RuntimeError('interrupted calibration')
        with self.assertRaises(RuntimeError): steering.prepare([Handle(0, 1, calibration='prompt')], fail)
        self.assertFalse(layer._forward_hooks)

if __name__ == '__main__': unittest.main()
