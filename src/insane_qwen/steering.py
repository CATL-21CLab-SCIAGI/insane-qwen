"""Validated, request-local activation interventions; all indices are zero-based."""
from contextlib import contextmanager
from dataclasses import asdict, dataclass
import math
import torch


@dataclass(frozen=True)
class Handle:
    layer: int = 20
    neuron: int = 8888
    operation: str = 'add'
    intensity: float = 0.6
    calibration: str = 'fixed'

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or set(value) - set(cls.__dataclass_fields__):
            raise ValueError('Invalid steering handle fields')
        h = cls(**value)
        if type(h.layer) is not int or not 0 <= h.layer < 32:
            raise ValueError('layer must be an integer in 0..31')
        if type(h.neuron) is not int or not 0 <= h.neuron < 9216:
            raise ValueError('neuron must be an integer in 0..9215')
        if h.operation not in ('add', 'multiply') or h.calibration not in ('fixed', 'prompt'):
            raise ValueError('Invalid operation or calibration')
        limit = 4 if h.operation == 'add' else 512
        if type(h.intensity) not in (int, float) or not math.isfinite(h.intensity) or abs(h.intensity) > limit:
            raise ValueError(f'intensity must be finite and within +/-{limit}')
        return h


def handles(value=None):
    if value is None: return [Handle()]
    values = value if isinstance(value, list) else [value]
    if not 1 <= len(values) <= 8: raise ValueError('Use one to eight neuron handles')
    result = [Handle.parse(v) for v in values]
    if len({(h.layer, h.neuron) for h in result}) != len(result):
        raise ValueError('Duplicate neuron positions are ambiguous')
    return result


DEFAULT = asdict(Handle())
LYRA = [asdict(Handle(14, 8949, intensity=1, calibration='prompt')),
        asdict(Handle(13, 7956, intensity=-1, calibration='prompt'))]


class Steering:
    def __init__(self, layers, residual_medians):
        self.layers = layers
        self.medians = {int(k): v for k, v in residual_medians.items()}

    def prepare(self, recipe, forward):
        medians, hooks = {}, []
        def capture(index):
            def hook(module, args, output):
                h = output[0] if isinstance(output, tuple) else output
                if h.shape[0] != 1 or h.shape[1] < 2:
                    raise ValueError('Prompt calibration requires at least two tokens')
                medians[index] = h[0, 1:].detach().float().norm(dim=-1).median()
            return hook
        try:
            for layer in {h.layer for h in recipe if h.operation == 'add' and h.calibration == 'prompt'}:
                hooks.append(self.layers[layer].register_forward_hook(capture(layer)))
            if hooks: forward()
        finally:
            for hook in hooks: hook.remove()
        values = []
        for h in recipe:
            value = h.intensity
            if h.operation == 'add':
                w = self.layers[h.layer].mlp.down_proj.weight[:, h.neuron].detach().float()
                norm = w.norm()
                if not torch.isfinite(norm) or norm <= 0: raise ValueError('Invalid column norm')
                residual = medians[h.layer] if h.calibration == 'prompt' else self.medians[h.layer]
                value = h.intensity * residual / norm
                if not torch.isfinite(value): raise ValueError('Invalid calibrated offset')
            values.append((h, value))
        return values

    @contextmanager
    def apply(self, values):
        hooks = []
        def intervene(h, value):
            def hook(module, args):
                activation = args[0].clone()
                if h.operation == 'add': activation[..., h.neuron] += torch.as_tensor(value).to(activation)
                else: activation[..., h.neuron] *= value
                return (activation, *args[1:])
            return hook
        try:
            for h, value in values:
                hooks.append(self.layers[h.layer].mlp.down_proj.register_forward_pre_hook(intervene(h, value)))
            yield
        finally:
            for hook in hooks: hook.remove()
