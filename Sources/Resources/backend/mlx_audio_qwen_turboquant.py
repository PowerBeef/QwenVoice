"""Repo-owned Talker KV-cache strategies for QwenVoice research spikes.

This module keeps the dense default intact while exposing two internal cache
experiments for Qwen3-TTS Talker:

* ``mlx_quantized`` uses MLX's built-in ``QuantizedKVCache`` conversion.
* ``turboquant`` uses a repo-owned hybrid cache that stores a dense sink and
  hot tail while compressing finalized prefix chunks with a deterministic
  Hadamard rotation, recursive polar quantization, and a 1-bit residual sketch
  for keys.

The implementation intentionally stays pure Python / NumPy / MLX so it can be
vendored into the shipped runtime without compiled extensions.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import mlx.core as mx
import numpy as np
from mlx_lm.models.cache import KVCache, create_attention_mask

DEFAULT_KV_CACHE_STRATEGY = "dense"
DEFAULT_KV_BITS = 4
DEFAULT_KV_GROUP_SIZE = 64
DEFAULT_QUANTIZED_KV_START = 128
DEFAULT_KV_QUANT_TARGET = "talker"
DEFAULT_TURBOQUANT_PROFILE = "tq35"
DEFAULT_TURBOQUANT_SINK_TOKENS = 128
DEFAULT_TURBOQUANT_CHUNK_SIZE = 128
DEFAULT_TURBOQUANT_SEED = 42

SUPPORTED_KV_CACHE_STRATEGIES = {"dense", "mlx_quantized", "turboquant"}
SUPPORTED_TURBOQUANT_PROFILES = {"tq35"}
_POLAR_BITS_PER_SPLIT = 2
_POLAR_LEVELS = 7


def _parse_optional_int(raw_value: Any, field_name: str) -> int | None:
    if raw_value is None:
        return None
    try:
        return int(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be an integer") from exc


def normalize_talker_cache_settings(
    *,
    kv_cache_strategy: str | None = None,
    kv_bits: int | None = None,
    kv_group_size: int = DEFAULT_KV_GROUP_SIZE,
    quantized_kv_start: int = DEFAULT_QUANTIZED_KV_START,
    turboquant_profile: str | None = None,
    turboquant_sink_tokens: int = DEFAULT_TURBOQUANT_SINK_TOKENS,
    turboquant_chunk_size: int = DEFAULT_TURBOQUANT_CHUNK_SIZE,
    turboquant_seed: int = DEFAULT_TURBOQUANT_SEED,
    kv_quant_target: str | None = None,
) -> dict[str, Any]:
    raw_strategy = (str(kv_cache_strategy).strip().lower() if kv_cache_strategy else "")
    legacy_quant_requested = any(
        value is not None
        for value in (kv_bits, kv_group_size, quantized_kv_start)
    ) and raw_strategy == ""
    strategy = raw_strategy or (
        "mlx_quantized" if legacy_quant_requested else DEFAULT_KV_CACHE_STRATEGY
    )
    if strategy not in SUPPORTED_KV_CACHE_STRATEGIES:
        raise ValueError(
            "kv_cache_strategy must be one of: dense, mlx_quantized, turboquant"
        )

    target = (
        (str(kv_quant_target).strip().lower() if kv_quant_target is not None else "")
        or DEFAULT_KV_QUANT_TARGET
    )
    if target != DEFAULT_KV_QUANT_TARGET:
        raise ValueError("kv_quant_target must be 'talker' for this prototype")

    settings: dict[str, Any] = {
        "kv_cache_strategy": strategy,
        "kv_quant_target": target,
    }
    if strategy == "dense":
        return settings

    if strategy == "mlx_quantized":
        resolved_bits = (
            DEFAULT_KV_BITS
            if kv_bits is None
            else _parse_optional_int(kv_bits, "kv_bits")
        )
        resolved_group_size = _parse_optional_int(kv_group_size, "kv_group_size")
        resolved_quantized_start = _parse_optional_int(
            quantized_kv_start, "quantized_kv_start"
        )
        if resolved_bits is None or resolved_bits <= 0:
            raise ValueError("kv_bits must be a positive integer")
        if resolved_group_size is None or resolved_group_size <= 0:
            raise ValueError("kv_group_size must be a positive integer")
        if resolved_quantized_start is None or resolved_quantized_start < 0:
            raise ValueError("quantized_kv_start must be zero or a positive integer")
        settings.update(
            {
                "kv_bits": resolved_bits,
                "kv_group_size": resolved_group_size,
                "quantized_kv_start": resolved_quantized_start,
            }
        )
        return settings

    if kv_bits is not None:
        raise ValueError("kv_bits is only supported with kv_cache_strategy='mlx_quantized'")

    profile = (
        (str(turboquant_profile).strip().lower() if turboquant_profile else "")
        or DEFAULT_TURBOQUANT_PROFILE
    )
    if profile not in SUPPORTED_TURBOQUANT_PROFILES:
        raise ValueError("Only turboquant_profile='tq35' is supported")

    sink_tokens = _parse_optional_int(turboquant_sink_tokens, "turboquant_sink_tokens")
    chunk_size = _parse_optional_int(turboquant_chunk_size, "turboquant_chunk_size")
    seed = _parse_optional_int(turboquant_seed, "turboquant_seed")
    if sink_tokens is None or sink_tokens < 0:
        raise ValueError("turboquant_sink_tokens must be zero or a positive integer")
    if chunk_size is None or chunk_size <= 0:
        raise ValueError("turboquant_chunk_size must be a positive integer")
    if seed is None:
        raise ValueError("turboquant_seed must be an integer")
    settings.update(
        {
            "turboquant_profile": profile,
            "turboquant_sink_tokens": sink_tokens,
            "turboquant_chunk_size": chunk_size,
            "turboquant_seed": seed,
        }
    )
    return settings


def build_talker_cache(talker, cache_settings: dict[str, Any] | None):
    settings = cache_settings or normalize_talker_cache_settings()
    dense_cache = talker.make_cache()
    if settings["kv_cache_strategy"] != "turboquant":
        return dense_cache
    return [
        TurboQuantKVCache(
            profile=str(settings["turboquant_profile"]),
            sink_tokens=int(settings["turboquant_sink_tokens"]),
            chunk_size=int(settings["turboquant_chunk_size"]),
            seed=int(settings["turboquant_seed"]),
        )
        for _ in dense_cache
    ]


def update_talker_cache_after_forward(
    cache_entries,
    cache_settings: dict[str, Any] | None,
) -> None:
    settings = cache_settings or normalize_talker_cache_settings()
    if settings["kv_cache_strategy"] != "mlx_quantized":
        return

    kv_bits = int(settings["kv_bits"])
    kv_group_size = int(settings["kv_group_size"])
    quantized_kv_start = int(settings["quantized_kv_start"])
    for index, cache_entry in enumerate(cache_entries):
        if hasattr(cache_entry, "bits"):
            continue
        if hasattr(cache_entry, "to_quantized") and cache_entry.offset >= quantized_kv_start:
            cache_entries[index] = cache_entry.to_quantized(
                group_size=kv_group_size,
                bits=kv_bits,
            )


def collect_talker_cache_stats(cache_entries) -> dict[str, Any]:
    total_bytes = 0
    total_dense_equivalent = 0
    for cache_entry in cache_entries:
        total_bytes += _infer_logical_cache_nbytes(cache_entry)
        dense_equivalent = _safe_property(cache_entry, "dense_equivalent_nbytes")
        if dense_equivalent is None:
            dense_equivalent = _infer_dense_equivalent_nbytes(cache_entry)
        total_dense_equivalent += int(dense_equivalent or 0)

    compression_ratio = None
    if total_dense_equivalent > 0:
        compression_ratio = round(total_bytes / total_dense_equivalent, 4)

    return {
        "talker_cache_bytes": total_bytes,
        "talker_cache_dense_equivalent_bytes": total_dense_equivalent,
        "talker_cache_compression_ratio": compression_ratio,
    }


def attach_talker_cache_stats(result, cache_entries):
    stats = collect_talker_cache_stats(cache_entries)
    for key, value in stats.items():
        setattr(result, key, value)
    return result


def _infer_logical_cache_nbytes(cache_entry) -> int:
    keys = getattr(cache_entry, "keys", None)
    values = getattr(cache_entry, "values", None)
    offset = int(getattr(cache_entry, "offset", 0) or 0)
    if keys is None or values is None or offset <= 0:
        return int(_safe_property(cache_entry, "nbytes", 0) or 0)
    if isinstance(keys, (tuple, list)) and len(keys) == 3:
        return _logical_tuple_nbytes(keys, offset) + _logical_tuple_nbytes(values, offset)
    if hasattr(keys, "shape") and hasattr(values, "shape"):
        return _logical_array_nbytes(keys, offset) + _logical_array_nbytes(values, offset)
    return int(_safe_property(cache_entry, "nbytes", 0) or 0)


def _safe_property(obj: Any, name: str, default: Any = None) -> Any:
    try:
        return getattr(obj, name)
    except Exception:
        return default


def _logical_tuple_nbytes(parts: tuple[Any, ...] | list[Any], offset: int) -> int:
    return int(sum(_logical_array_nbytes(part, offset) for part in parts))


def _logical_array_nbytes(array: Any, offset: int) -> int:
    shape = getattr(array, "shape", None)
    dtype = getattr(array, "dtype", None)
    if shape is None or dtype is None or len(shape) < 4:
        return int(getattr(array, "nbytes", 0) or 0)
    used_tokens = min(offset, int(shape[2]))
    if used_tokens <= 0:
        return 0
    return int(shape[0]) * int(shape[1]) * used_tokens * int(shape[3]) * _dtype_nbytes(dtype)


def _dtype_nbytes(dtype: Any) -> int:
    if hasattr(dtype, "itemsize"):
        return int(dtype.itemsize)
    if hasattr(dtype, "size"):
        return int(dtype.size)
    return int(np.dtype(dtype).itemsize)


def _infer_dense_equivalent_nbytes(cache_entry) -> int:
    if hasattr(cache_entry, "keys") and hasattr(cache_entry, "values"):
        keys = getattr(cache_entry, "keys", None)
        values = getattr(cache_entry, "values", None)
        offset = int(getattr(cache_entry, "offset", 0) or 0)
        if keys is None or values is None or offset <= 0:
            return 0
        if isinstance(keys, (tuple, list)) and len(keys) == 3:
            packed, scales, _ = keys
            v_packed, v_scales, _ = values
            bits = int(getattr(cache_entry, "bits", 0) or 0)
            if bits <= 0:
                return 0
            per_word = (8 * mx.uint32.size) // bits
            key_dim = int(packed.shape[-1]) * per_word
            value_dim = int(v_packed.shape[-1]) * per_word
            batch, heads = int(packed.shape[0]), int(packed.shape[1])
            dtype_bytes = _dtype_nbytes(scales.dtype)
            return batch * heads * offset * (key_dim + value_dim) * dtype_bytes
        if isinstance(keys, np.ndarray) and isinstance(values, np.ndarray):
            return int(keys[..., :offset, :].nbytes + values[..., :offset, :].nbytes)
        if hasattr(keys, "shape") and hasattr(values, "shape") and hasattr(keys, "dtype"):
            key_shape = tuple(int(x) for x in keys.shape)
            value_shape = tuple(int(x) for x in values.shape)
            dtype_bytes = _dtype_nbytes(keys.dtype)
            return (
                key_shape[0] * key_shape[1] * offset * key_shape[3] * dtype_bytes
                + value_shape[0] * value_shape[1] * offset * value_shape[3] * dtype_bytes
            )
    return 0


@lru_cache(maxsize=None)
def _hadamard_matrix(dim: int) -> np.ndarray:
    if dim <= 0 or dim & (dim - 1):
        raise ValueError("Hadamard dimension must be a power of two")
    matrix = np.array([[1.0]], dtype=np.float32)
    while matrix.shape[0] < dim:
        matrix = np.block([[matrix, matrix], [matrix, -matrix]])
    return matrix / math.sqrt(dim)


@lru_cache(maxsize=None)
def _rademacher_signs(dim: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return rng.choice(np.array([-1.0, 1.0], dtype=np.float32), size=dim)


def _rotate(vectors: np.ndarray, seed: int) -> np.ndarray:
    dim = int(vectors.shape[-1])
    hadamard = _hadamard_matrix(dim)
    signs = _rademacher_signs(dim, seed)
    return (vectors.astype(np.float32) * signs) @ hadamard


def _inverse_rotate(vectors: np.ndarray, seed: int) -> np.ndarray:
    dim = int(vectors.shape[-1])
    hadamard = _hadamard_matrix(dim)
    signs = _rademacher_signs(dim, seed)
    return (vectors.astype(np.float32) @ hadamard) * signs


@lru_cache(maxsize=None)
def _polar_codebook(child_dim: int) -> np.ndarray:
    alpha = max(float(child_dim) / 2.0, 0.5)
    grid = np.linspace(1e-4, 1.0 - 1e-4, 8193, dtype=np.float64)
    log_pdf = (
        (alpha - 1.0) * np.log(grid)
        + (alpha - 1.0) * np.log1p(-grid)
        - (
            math.lgamma(alpha)
            + math.lgamma(alpha)
            - math.lgamma(alpha + alpha)
        )
    )
    weights = np.exp(log_pdf - np.max(log_pdf))
    cdf = np.cumsum(weights)
    cdf /= cdf[-1]
    quantiles = [0.0]
    for bucket in range(1, 4):
        idx = int(np.searchsorted(cdf, bucket / 4.0))
        quantiles.append(float(grid[min(idx, len(grid) - 1)]))
    quantiles.append(1.0)
    levels: list[float] = []
    for left, right in zip(quantiles[:-1], quantiles[1:]):
        mask = (grid >= left) & (grid <= right)
        masked_weights = weights[mask]
        masked_grid = grid[mask]
        if masked_weights.size == 0:
            levels.append((left + right) / 2.0)
        else:
            levels.append(float(np.average(masked_grid, weights=masked_weights)))
    return np.array(levels, dtype=np.float32)


def _quantize_polar_splits(vectors: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    n_vectors, dim = vectors.shape
    if dim != 128:
        raise ValueError("TurboQuant v1 requires head_dim == 128")

    squared = np.square(np.abs(vectors), dtype=np.float32)
    codes = np.zeros((n_vectors, dim - 1), dtype=np.uint8)
    offset = 0
    subtree = dim
    while subtree > 1:
        group_count = dim // subtree
        reshaped = squared.reshape(n_vectors, group_count, subtree)
        half = subtree // 2
        left_mass = reshaped[:, :, :half].sum(axis=-1)
        total_mass = reshaped.sum(axis=-1)
        ratios = np.divide(
            left_mass,
            total_mass,
            out=np.full_like(left_mass, 0.5, dtype=np.float32),
            where=total_mass > 0.0,
        )
        codebook = _polar_codebook(half)
        distances = np.abs(ratios[..., None] - codebook.reshape(1, 1, -1))
        chosen = np.argmin(distances, axis=-1).astype(np.uint8)
        codes[:, offset : offset + group_count] = chosen
        offset += group_count
        subtree //= 2

    norms = np.linalg.norm(vectors, axis=-1).astype(np.float16)
    sign_bits = _pack_bits(vectors >= 0.0)
    packed_codes = _pack_uint_codes(codes, bits=_POLAR_BITS_PER_SPLIT)
    return norms, np.concatenate([sign_bits, packed_codes], axis=-1)


def _dequantize_polar_splits(norms: np.ndarray, packed: np.ndarray, dim: int) -> np.ndarray:
    sign_width = _packed_bit_width(dim)
    packed_signs = packed[:, :sign_width]
    packed_codes = packed[:, sign_width:]
    signs = _unpack_bits(packed_signs, count=dim).astype(np.float32)
    signs = np.where(signs > 0.0, 1.0, -1.0)
    codes = _unpack_uint_codes(packed_codes, count=dim - 1, bits=_POLAR_BITS_PER_SPLIT)

    n_vectors = int(norms.shape[0])
    fractions = np.ones((n_vectors, 1), dtype=np.float32)
    offset = 0
    subtree = dim
    while subtree > 1:
        group_count = dim // subtree
        codebook = _polar_codebook(subtree // 2)
        chosen = codebook[codes[:, offset : offset + group_count]]
        left = fractions * chosen
        right = fractions * (1.0 - chosen)
        fractions = np.stack([left, right], axis=-1).reshape(n_vectors, group_count * 2)
        offset += group_count
        subtree //= 2

    magnitudes = np.sqrt(np.clip(fractions, 0.0, 1.0), dtype=np.float32)
    magnitudes *= norms.astype(np.float32).reshape(-1, 1)
    return magnitudes * signs


def _quantize_qjl_residual(vectors: np.ndarray, seed: int) -> tuple[np.ndarray, np.ndarray]:
    residual_rotated = _rotate(vectors, seed)
    norms = np.linalg.norm(vectors, axis=-1).astype(np.float16)
    return norms, _pack_bits(residual_rotated >= 0.0)


def _dequantize_qjl_residual(norms: np.ndarray, packed: np.ndarray, dim: int, seed: int) -> np.ndarray:
    signs = _unpack_bits(packed, count=dim).astype(np.float32)
    signs = np.where(signs > 0.0, 1.0, -1.0)
    reconstructed = _inverse_rotate(signs, seed)
    scale = np.float32(math.sqrt(math.pi / (2.0 * dim)))
    return reconstructed * norms.astype(np.float32).reshape(-1, 1) * scale


def _pack_bits(bits: np.ndarray) -> np.ndarray:
    return np.packbits(bits.astype(np.uint8), axis=-1, bitorder="little")


def _unpack_bits(packed: np.ndarray, *, count: int) -> np.ndarray:
    unpacked = np.unpackbits(packed.astype(np.uint8), axis=-1, bitorder="little")
    return unpacked[:, :count]


def _packed_bit_width(count: int) -> int:
    return (count + 7) // 8


def _pack_uint_codes(codes: np.ndarray, *, bits: int) -> np.ndarray:
    codes = codes.astype(np.uint8)
    per_byte = 8 // bits
    pad = (-codes.shape[-1]) % per_byte
    if pad:
        codes = np.pad(codes, ((0, 0), (0, pad)), mode="constant")
    reshaped = codes.reshape(codes.shape[0], -1, per_byte)
    packed = np.zeros(reshaped.shape[:2], dtype=np.uint8)
    mask = np.uint8((1 << bits) - 1)
    for index in range(per_byte):
        packed |= (reshaped[:, :, index] & mask) << np.uint8(index * bits)
    return packed


def _unpack_uint_codes(packed: np.ndarray, *, count: int, bits: int) -> np.ndarray:
    per_byte = 8 // bits
    unpacked = np.zeros((packed.shape[0], packed.shape[1] * per_byte), dtype=np.uint8)
    mask = np.uint8((1 << bits) - 1)
    for index in range(per_byte):
        unpacked[:, index::per_byte] = (packed >> np.uint8(index * bits)) & mask
    return unpacked[:, :count]


@dataclass
class _CompressedTurboChunk:
    batch: int
    heads: int
    tokens: int
    key_dim: int
    value_dim: int
    dtype: np.dtype
    key_norms: np.ndarray
    key_polar: np.ndarray
    key_residual_norms: np.ndarray
    key_residual_signs: np.ndarray
    value_norms: np.ndarray
    value_polar: np.ndarray

    @property
    def nbytes(self) -> int:
        arrays = (
            self.key_norms,
            self.key_polar,
            self.key_residual_norms,
            self.key_residual_signs,
            self.value_norms,
            self.value_polar,
        )
        return int(sum(arr.nbytes for arr in arrays))

    @property
    def dense_equivalent_nbytes(self) -> int:
        itemsize = int(self.dtype.itemsize)
        return (
            self.batch
            * self.heads
            * self.tokens
            * (self.key_dim + self.value_dim)
            * itemsize
        )


def _compress_chunk(
    keys: np.ndarray,
    values: np.ndarray,
    *,
    seed: int,
) -> _CompressedTurboChunk:
    batch, heads, tokens, key_dim = keys.shape
    value_dim = int(values.shape[-1])
    key_vectors = keys.astype(np.float32).reshape(-1, key_dim)
    value_vectors = values.astype(np.float32).reshape(-1, value_dim)

    key_rotated = _rotate(key_vectors, seed)
    value_rotated = _rotate(value_vectors, seed)

    key_norms, key_polar = _quantize_polar_splits(key_rotated)
    value_norms, value_polar = _quantize_polar_splits(value_rotated)

    key_base = _dequantize_polar_splits(key_norms, key_polar, key_dim)
    residual = key_rotated - key_base
    key_residual_norms, key_residual_signs = _quantize_qjl_residual(residual, seed + 1)

    return _CompressedTurboChunk(
        batch=batch,
        heads=heads,
        tokens=tokens,
        key_dim=key_dim,
        value_dim=value_dim,
        dtype=keys.dtype,
        key_norms=key_norms.reshape(batch, heads, tokens),
        key_polar=key_polar.reshape(batch, heads, tokens, -1),
        key_residual_norms=key_residual_norms.reshape(batch, heads, tokens),
        key_residual_signs=key_residual_signs.reshape(batch, heads, tokens, -1),
        value_norms=value_norms.reshape(batch, heads, tokens),
        value_polar=value_polar.reshape(batch, heads, tokens, -1),
    )


def _decompress_chunk(chunk: _CompressedTurboChunk, *, seed: int) -> tuple[np.ndarray, np.ndarray]:
    key_vectors = _dequantize_polar_splits(
        chunk.key_norms.reshape(-1),
        chunk.key_polar.reshape(-1, chunk.key_polar.shape[-1]),
        chunk.key_dim,
    )
    key_residual = _dequantize_qjl_residual(
        chunk.key_residual_norms.reshape(-1),
        chunk.key_residual_signs.reshape(-1, chunk.key_residual_signs.shape[-1]),
        chunk.key_dim,
        seed + 1,
    )
    key_vectors = _inverse_rotate(key_vectors + key_residual, seed)
    value_vectors = _dequantize_polar_splits(
        chunk.value_norms.reshape(-1),
        chunk.value_polar.reshape(-1, chunk.value_polar.shape[-1]),
        chunk.value_dim,
    )
    value_vectors = _inverse_rotate(value_vectors, seed)
    keys = key_vectors.reshape(chunk.batch, chunk.heads, chunk.tokens, chunk.key_dim)
    values = value_vectors.reshape(chunk.batch, chunk.heads, chunk.tokens, chunk.value_dim)
    dtype = chunk.dtype
    return keys.astype(dtype, copy=False), values.astype(dtype, copy=False)


class TurboQuantKVCache:
    """Hybrid cache with dense sink/hot tail and compressed finalized prefix."""

    def __init__(
        self,
        *,
        profile: str = DEFAULT_TURBOQUANT_PROFILE,
        sink_tokens: int = DEFAULT_TURBOQUANT_SINK_TOKENS,
        chunk_size: int = DEFAULT_TURBOQUANT_CHUNK_SIZE,
        seed: int = DEFAULT_TURBOQUANT_SEED,
    ) -> None:
        if profile not in SUPPORTED_TURBOQUANT_PROFILES:
            raise ValueError("Only turboquant_profile='tq35' is supported")
        self.profile = profile
        self.sink_tokens = int(sink_tokens)
        self.chunk_size = int(chunk_size)
        self.seed = int(seed)
        self.offset = 0
        self._key_dtype: np.dtype | None = None
        self._value_dtype: np.dtype | None = None
        self._dense_sink_k: np.ndarray | None = None
        self._dense_sink_v: np.ndarray | None = None
        self._cold_buffer_k: np.ndarray | None = None
        self._cold_buffer_v: np.ndarray | None = None
        self._hot_tail_k: np.ndarray | None = None
        self._hot_tail_v: np.ndarray | None = None
        self._chunks: list[_CompressedTurboChunk] = []

    def update_and_fetch(self, keys, values):
        keys_np = _mlx_to_numpy(keys)
        values_np = _mlx_to_numpy(values)
        if keys_np.ndim != 4 or values_np.ndim != 4:
            raise ValueError("TurboQuantKVCache expects [B, H, T, D] tensors")
        if int(keys_np.shape[-1]) != 128 or int(values_np.shape[-1]) != 128:
            raise ValueError("TurboQuant v1 requires Talker head_dim == 128")

        if self._key_dtype is None:
            self._key_dtype = keys_np.dtype
            self._value_dtype = values_np.dtype
        self.offset += int(keys_np.shape[2])
        self._append_dense_tokens(keys_np, values_np)
        while self._cold_buffer_len() >= self.chunk_size:
            self._compress_oldest_cold_chunk()

        full_keys, full_values = self._materialize()
        return (
            mx.array(full_keys, dtype=keys.dtype),
            mx.array(full_values, dtype=values.dtype),
        )

    def size(self):
        return self.offset

    def empty(self):
        return self.offset == 0

    def make_mask(self, *args, **kwargs):
        return create_attention_mask(*args, offset=self.offset, **kwargs)

    @property
    def nbytes(self):
        dense_arrays = (
            self._dense_sink_k,
            self._dense_sink_v,
            self._cold_buffer_k,
            self._cold_buffer_v,
            self._hot_tail_k,
            self._hot_tail_v,
        )
        dense_bytes = sum(int(arr.nbytes) for arr in dense_arrays if arr is not None)
        return dense_bytes + sum(chunk.nbytes for chunk in self._chunks)

    @property
    def dense_equivalent_nbytes(self):
        if self.offset <= 0 or self._key_dtype is None:
            return 0
        key_dim = self._infer_dim(self._dense_sink_k, self._cold_buffer_k, self._hot_tail_k, self._chunks, is_key=True)
        value_dim = self._infer_dim(self._dense_sink_v, self._cold_buffer_v, self._hot_tail_v, self._chunks, is_key=False)
        if key_dim == 0 or value_dim == 0:
            return 0
        batch, heads = self._infer_batch_heads()
        itemsize = int(self._key_dtype.itemsize)
        return batch * heads * self.offset * (key_dim + value_dim) * itemsize

    def _infer_batch_heads(self) -> tuple[int, int]:
        for arr in (self._dense_sink_k, self._cold_buffer_k, self._hot_tail_k):
            if arr is not None:
                return int(arr.shape[0]), int(arr.shape[1])
        if self._chunks:
            chunk = self._chunks[0]
            return chunk.batch, chunk.heads
        return 0, 0

    def _infer_dim(self, sink, cold, hot, chunks, *, is_key: bool) -> int:
        for arr in (sink, cold, hot):
            if arr is not None:
                return int(arr.shape[-1])
        if chunks:
            return chunks[0].key_dim if is_key else chunks[0].value_dim
        return 0

    def _append_dense_tokens(self, keys_np: np.ndarray, values_np: np.ndarray) -> None:
        remaining_k = keys_np
        remaining_v = values_np
        sink_len = self._dense_sink_len()
        if sink_len < self.sink_tokens:
            need = min(self.sink_tokens - sink_len, int(keys_np.shape[2]))
            if need > 0:
                self._dense_sink_k = _append_time(self._dense_sink_k, remaining_k[:, :, :need, :])
                self._dense_sink_v = _append_time(self._dense_sink_v, remaining_v[:, :, :need, :])
                remaining_k = remaining_k[:, :, need:, :]
                remaining_v = remaining_v[:, :, need:, :]

        if remaining_k.shape[2] > 0:
            self._hot_tail_k = _append_time(self._hot_tail_k, remaining_k)
            self._hot_tail_v = _append_time(self._hot_tail_v, remaining_v)

        while self._hot_tail_len() > self.chunk_size:
            spill = self._hot_tail_len() - self.chunk_size
            self._cold_buffer_k = _append_time(self._cold_buffer_k, self._hot_tail_k[:, :, :spill, :])
            self._cold_buffer_v = _append_time(self._cold_buffer_v, self._hot_tail_v[:, :, :spill, :])
            self._hot_tail_k = self._hot_tail_k[:, :, spill:, :]
            self._hot_tail_v = self._hot_tail_v[:, :, spill:, :]

    def _compress_oldest_cold_chunk(self) -> None:
        if self._cold_buffer_k is None or self._cold_buffer_v is None:
            return
        chunk_k = self._cold_buffer_k[:, :, : self.chunk_size, :]
        chunk_v = self._cold_buffer_v[:, :, : self.chunk_size, :]
        self._chunks.append(_compress_chunk(chunk_k, chunk_v, seed=self.seed))
        self._cold_buffer_k = _trim_leading_tokens(self._cold_buffer_k, self.chunk_size)
        self._cold_buffer_v = _trim_leading_tokens(self._cold_buffer_v, self.chunk_size)

    def _materialize(self) -> tuple[np.ndarray, np.ndarray]:
        key_parts: list[np.ndarray] = []
        value_parts: list[np.ndarray] = []
        if self._dense_sink_k is not None:
            key_parts.append(self._dense_sink_k)
            value_parts.append(self._dense_sink_v)
        for chunk in self._chunks:
            chunk_k, chunk_v = _decompress_chunk(chunk, seed=self.seed)
            key_parts.append(chunk_k)
            value_parts.append(chunk_v)
        if self._cold_buffer_k is not None:
            key_parts.append(self._cold_buffer_k)
            value_parts.append(self._cold_buffer_v)
        if self._hot_tail_k is not None:
            key_parts.append(self._hot_tail_k)
            value_parts.append(self._hot_tail_v)
        if not key_parts:
            raise RuntimeError("TurboQuantKVCache contains no materialized state")
        return np.concatenate(key_parts, axis=2), np.concatenate(value_parts, axis=2)

    def _dense_sink_len(self) -> int:
        return 0 if self._dense_sink_k is None else int(self._dense_sink_k.shape[2])

    def _cold_buffer_len(self) -> int:
        return 0 if self._cold_buffer_k is None else int(self._cold_buffer_k.shape[2])

    def _hot_tail_len(self) -> int:
        return 0 if self._hot_tail_k is None else int(self._hot_tail_k.shape[2])


def _append_time(base: np.ndarray | None, new: np.ndarray) -> np.ndarray:
    if base is None:
        return np.array(new, copy=True)
    return np.concatenate([base, new], axis=2)


def _trim_leading_tokens(base: np.ndarray | None, count: int) -> np.ndarray | None:
    if base is None:
        return None
    if count >= base.shape[2]:
        return None
    return base[:, :, count:, :]


def _mlx_to_numpy(array: Any) -> np.ndarray:
    if isinstance(array, np.ndarray):
        return array
    try:
        return np.asarray(array)
    except RuntimeError:
        if hasattr(array, "astype"):
            return np.asarray(array.astype(mx.float16))
        raise
