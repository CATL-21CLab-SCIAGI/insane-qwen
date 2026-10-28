"""Freeze candidates from a completed scan before any held-out generations."""
import hashlib
import json
from pathlib import Path

import numpy as np


def rank(folder):
    completion=json.loads((folder/'completion.json').read_text())
    assert completion['layers']==32
    rows=[]; null=[]
    for layer in range(32):
        # NPZ reads are lazy: materialize each array once, not once per neuron.
        with np.load(folder/f'layer-{layer:02d}.npz') as archive:
            data=dict(archive)
        for pole in ['up','down']:
            for kind,sink in [('neuron',rows),('random',null)]:
                for n,score in enumerate(data[f'{kind}_{pole}_score']):
                    kl=float(data[f'{kind}_{pole}_kl'][n])
                    sink.append({'layer':layer,'neuron' if kind=='neuron' else 'direction':n,
                        'pole':pole,'sign':1 if pole=='up' else -1,'score':float(score),'kl':kl,
                        'eligible':layer>=3 and kl<=3,
                        'hostility_delta':float(data[f'{kind}_{pole}_hostility'][n]),
                        'kindness_delta':float(data[f'{kind}_{pole}_kindness'][n]),
                        'tokens':data[f'{kind}_{pole}_tokens'][n].tolist(),
                        'deltas':data[f'{kind}_{pole}_deltas'][n].tolist()})
    eligible=sorted([r for r in rows if r['eligible']],key=lambda r:(-r['score'],r['layer'],r['neuron'],r['pole']))
    null_eligible=[r for r in null if r['eligible']]
    candidates=[]; seen=set()
    for r in eligible:
        key=(r['layer'],r['neuron'])
        if key in seen: continue
        candidates.append(dict(r,rank=len(candidates)+1)); seen.add(key)
        if len(candidates)==4: break
    for r in candidates:
        layer_null=[n['score'] for n in null_eligible if n['layer']==r['layer']]
        r['fraction_layer_null_scoring_at_least_as_high']=sum(s>=r['score'] for s in layer_null)/len(layer_null)
        r['layer_null_count']=len(layer_null)
    # Null benchmark is descriptive: selection over many neurons invalidates a naive p-value.
    output={'rule':'predeclared top four distinct neurons, layers >=3 and KL<=3',
        'candidate_count':len(eligible),'all_neuron_poles':len(rows),'random_poles':len(null),
        'selected':candidates,'top_50':eligible[:50],
        'null_score_quantiles':dict(zip(['min','median','p95','p99','max'],np.quantile([r['score'] for r in null_eligible],[0,.5,.95,.99,1]).tolist())),
        'warning':'Lexical next-token score is a discovery proxy, not a personality rating. Random percentiles are descriptive, not corrected significance tests.',
        'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (folder/'frozen-candidates.json').write_text(json.dumps(output,indent=2)+'\n')
    print(json.dumps({k:v for k,v in output.items() if k!='top_50'},indent=2))
