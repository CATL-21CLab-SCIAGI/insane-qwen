"""Reproduce Lyra's four-context causal steer lens; add fixed trait scores and null controls.

Algorithm reference: lyramakesmusic/neuron-explorer, ddb144e4, sweep/steer_lens.py.
No known neuron IDs enter the scan or its ranking. All MLP layers/neurons and
both poles are enumerated. No weights are changed or services reconfigured.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
import transformers
from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration


from .kernels import enable_fla

CHAT = ['Who are you?', 'Write whatever you like.']
PLAIN = ['I think the most important thing to remember is', 'Today we are going to talk about']
TRAITS = {
    'hostility': ['evil','cruel','malicious','sadistic','harm','suffering','torment','hatred','abuse','violent','deceive','manipulate','ruthless','vicious','恶意','残忍','伤害','仇恨'],
    'kindness': ['kind','kindness','helpful','gentle','compassion','caring','supportive','honest','ethical','benevolent','friendly','respectful','善良','友善','帮助','温柔'],
}


def write_json(path, data): path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')


class Scanner:
    def __init__(self, model_path, out, batch, dose):
        torch.cuda.set_per_process_memory_fraction(.65)
        self.tok = AutoTokenizer.from_pretrained(model_path,local_files_only=True)
        self.model = Qwen3_5ForConditionalGeneration.from_pretrained(model_path,dtype=torch.bfloat16,
            device_map='cuda:0',attn_implementation='sdpa',local_files_only=True).eval()
        self.lm = self.model.model.language_model
        self.out,self.batch,self.dose = out,batch,dose
        contexts = [self.tok.apply_chat_template([{'role':'user','content':c}],tokenize=True,
            return_dict=False,add_generation_prompt=True,enable_thinking=False) for c in CHAT]
        contexts += [self.tok(p).input_ids for p in PLAIN]
        self.C,self.T = len(contexts),max(map(len,contexts))
        pad = self.tok.pad_token_id or 0
        self.ids = torch.tensor([[pad]*(self.T-len(c))+c for c in contexts],device='cuda')
        self.mask = torch.tensor([[0]*(self.T-len(c))+[1]*len(c) for c in contexts],device='cuda')
        self.pos = (self.mask.cumsum(-1)-1).clamp(min=0)
        self.push = None
        self.capture = True
        self.norms = {}
        self.handles = []
        for i, layer in enumerate(self.lm.layers):
            self.handles.append(layer.mlp.down_proj.register_forward_pre_hook(self.pre_hook(i)))
            self.handles.append(layer.mlp.down_proj.register_forward_hook(self.post_hook(i)))
            self.handles.append(layer.register_forward_hook(self.resid_hook(i)))
        self.base = self.logprobs(self.ids,self.mask,self.pos)
        self.capture = False
        self.trait_ids = {}
        token_report = {}
        for trait, words in TRAITS.items():
            found = set()
            for word in words:
                for surface in [word,' '+word,word.title(),' '+word.title()]:
                    ids = self.tok.encode(surface,add_special_tokens=False)
                    if len(ids)==1: found.add(ids[0])
            assert len(found)>=10
            self.trait_ids[trait] = torch.tensor(sorted(found),device='cuda')
            token_report[trait] = [{'id':n,'text':self.tok.decode([n])} for n in sorted(found)]
        write_json(out/'calibration.json',{'residual_medians':self.norms,'context_token_ids':contexts,
            'normalization':'upstream scan: median over real tokens across four contexts, including first real token',
            'trait_tokens':token_report})

    def resid_hook(self,i):
        def hook(module,args,out):
            if self.capture:
                h = out[0] if isinstance(out,tuple) else out
                self.norms[i] = float(h[self.mask.bool()].float().norm(dim=-1).median())
        return hook

    def pre_hook(self,i):
        def hook(module,args):
            p=self.push
            if p is None or p['layer']!=i or p['kind']!='neuron': return
            h=args[0].clone()
            rows=torch.arange(h.shape[0],device=h.device)
            h[rows,:,p['cols']] += p['vals'][:,None].to(h.dtype)
            return (h,*args[1:])
        return hook

    def post_hook(self,i):
        def hook(module,args,out):
            p=self.push
            if p is None or p['layer']!=i or p['kind']!='random': return
            return out + p['vectors'][:,None,:].to(out.dtype)
        return hook

    def logprobs(self,ids,mask,pos):
        h=self.lm(input_ids=ids,attention_mask=mask,position_ids=pos,use_cache=False).last_hidden_state[:,-1]
        return torch.log_softmax(self.model.lm_head(h).float(),-1)

    def run_batch(self,layer,indices,sign,kind='neuron',directions=None):
        b=len(indices)
        if kind=='neuron':
            w=self.lm.layers[layer].mlp.down_proj.weight
            cols=indices.repeat_interleave(self.C)
            scale=sign*self.dose*self.norms[layer]/w[:,indices].float().norm(dim=0)
            self.push={'kind':kind,'layer':layer,'cols':cols,'vals':scale.repeat_interleave(self.C)}
        else:
            vectors=directions[indices]*sign*self.dose*self.norms[layer]
            self.push={'kind':kind,'layer':layer,'vectors':vectors.repeat_interleave(self.C,dim=0)}
        try:
            lp=self.logprobs(self.ids.repeat(b,1),self.mask.repeat(b,1),self.pos.repeat(b,1)).view(b,self.C,-1)
        finally: self.push=None
        delta=(lp-self.base[None]).mean(1)
        values,tokens=delta.topk(12)
        kl=(lp.exp()*(lp-self.base[None])).sum(-1).mean(1)
        masses={}
        for trait,ids in self.trait_ids.items():
            masses[trait]=(lp[:,:,ids].logsumexp(-1)-self.base[:,ids].logsumexp(-1)[None]).mean(1)
        result={'tokens':tokens.int().cpu().numpy(),'deltas':values.cpu().numpy(),'kl':kl.cpu().numpy(),
                'hostility':masses['hostility'].cpu().numpy(),'kindness':masses['kindness'].cpu().numpy(),
                'score':(masses['hostility']-masses['kindness']).cpu().numpy()}
        assert all(np.isfinite(v).all() for v in result.values())
        return result

    def qualify(self):
        # Arbitrary fixed neurons, not known character examples.
        chosen=torch.tensor([17,503,2201,7003],device='cuda')
        batch=self.run_batch(14,chosen,1.)
        singles=[self.run_batch(14,n[None],1.) for n in chosen]
        score_error=float(np.max(np.abs(batch['score']-np.concatenate([x['score'] for x in singles]))))
        kl_error=float(np.max(np.abs(batch['kl']-np.concatenate([x['kl'] for x in singles]))))
        restored=self.logprobs(self.ids,self.mask,self.pos)
        restore_error=float((restored-self.base).abs().max())
        assert score_error<.25 and kl_error<.25 and restore_error==0
        # The first full-size batch can compile Triton kernels; exclude it.
        self.run_batch(14,torch.arange(self.batch,device='cuda'),1.)
        timings=[]
        for _ in range(3):
            started=time.monotonic()
            self.run_batch(14,torch.arange(self.batch,device='cuda'),1.)
            timings.append(time.monotonic()-started)
        seconds=float(np.median(timings))
        report={'batch_score_max_error':score_error,'batch_kl_max_error':kl_error,
                'original_restored_exactly':restore_error==0,'neurons_per_batch':self.batch,
                'seconds_per_batch':seconds,'timings':timings,'estimated_full_scan_seconds':seconds*32*2*np.ceil(9216/self.batch)}
        np.savez_compressed(self.out/'qualification-values.npz',base=self.base.cpu().numpy(),**batch)
        write_json(self.out/'qualification.json',report)
        print(json.dumps({'qualification':report}),flush=True)
        return report

    def scan_layer(self,layer,controls):
        path=self.out/f'layer-{layer:02d}.npz'
        if path.exists(): return
        n=self.lm.layers[layer].mlp.down_proj.weight.shape[1]
        rng=torch.Generator(device='cuda').manual_seed(1709+layer)
        directions=torch.randn(controls,self.lm.layers[layer].mlp.down_proj.weight.shape[0],generator=rng,device='cuda')
        directions /= directions.norm(dim=-1,keepdim=True)
        arrays={}; start=time.monotonic()
        for kind,total in [('neuron',n),('random',controls)]:
            for sign,label in [(1.,'up'),(-1.,'down')]:
                blocks=[]
                for s in range(0,total,self.batch):
                    indices=torch.arange(s,min(s+self.batch,total),device='cuda')
                    blocks.append(self.run_batch(layer,indices,sign,kind,directions))
                    if kind=='neuron' and (s//self.batch)%16==0:
                        print(json.dumps({'layer':layer,'pole':label,'neurons_done':min(s+self.batch,total),'seconds':round(time.monotonic()-start,1)}),flush=True)
                for field in blocks[0]: arrays[f'{kind}_{label}_{field}']=np.concatenate([x[field] for x in blocks])
        restored=self.logprobs(self.ids,self.mask,self.pos)
        assert torch.equal(restored,self.base)
        np.savez_compressed(path,**arrays,layer=layer,dose=self.dose,seconds=time.monotonic()-start)
        print(json.dumps({'layer_complete':layer,'seconds':round(time.monotonic()-start,1)}),flush=True)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--model',required=True); ap.add_argument('--output',required=True)
    ap.add_argument('--batch',type=int,default=96); ap.add_argument('--dose',type=float,default=.8)
    ap.add_argument('--controls',type=int,default=64)
    ap.add_argument('--qualify-only',action='store_true')
    ap.add_argument('--fla',action='store_true')
    a=ap.parse_args(); out=Path(a.output); out.mkdir(parents=True,exist_ok=False)
    if a.fla: enable_fla()
    write_json(out/'contract.json',{'created_at':datetime.now(timezone.utc).isoformat(),'upstream_commit':'ddb144e4121fbeb16ec080077dd67247e499132d',
        'model':a.model,'layers':list(range(32)),'neurons_per_layer':9216,'poles':[-1,1],'dose':a.dose,
        'chat_contexts':CHAT,'plain_contexts':PLAIN,'trait_terms':TRAITS,'score':'mean_context delta log P(hostility token set) minus delta log P(kindness token set)',
        'ranking':'rank eligible neuron poles by score; exclude layers 0-2 and KL>3 from validation shortlist; choose top 4 distinct neurons without ID injection',
        'controls_per_layer':a.controls,'control_seed':'1709+layer','random_direction_norm':'same residual-norm dose as neurons',
        'torch':torch.__version__,'transformers':transformers.__version__,'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'qualification_only':a.qualify_only,'kernel':'fla-core 0.6.0' if a.fla else 'transformers torch reference','differences':'Retains upstream full forward, context, norm and +/- dose. Adds fixed hostility/kindness scores, Gaussian output-direction controls, finite/restore checks, and incremental layer saves. Does not rerun the exhaustive rollout sweep.'})
    with torch.inference_mode():
        scan=Scanner(a.model,out,a.batch,a.dose); scan.qualify()
        if not a.qualify_only:
            started=time.monotonic()
            for layer in range(32): scan.scan_layer(layer,a.controls)
            write_json(out/'completion.json',{'layers':32,'neuron_poles':32*9216*2,'random_poles':32*a.controls*2,'seconds':time.monotonic()-started})
    print('COMPLETE',flush=True)
    return None if a.qualify_only else out


if __name__=='__main__': main()
