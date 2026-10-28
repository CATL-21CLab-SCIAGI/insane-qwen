"""Optional process-local linear-attention acceleration."""
def enable_fla():
    import transformers.models.qwen3_5.modeling_qwen3_5 as qwen
    from fla.ops.gated_delta_rule import chunk_gated_delta_rule, fused_recurrent_gated_delta_rule
    qwen.torch_chunk_gated_delta_rule = chunk_gated_delta_rule
    qwen.torch_recurrent_gated_delta_rule = fused_recurrent_gated_delta_rule
