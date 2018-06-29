#include "ATen/ATen.h"
#include "ATen/TensorUtils.h"
#include "ATen/Error.h"

#include "ATen/AccumulateType.h"

#include <THC/THCDeviceUtils.cuh>
#include <THC/THCTensorMathReduce.cuh>
#include <THC/THCTensorSort.cuh>
#include <THC/THCThrustAllocator.cuh>

#include <thrust/execution_policy.h>
#include <thrust/unique.h>


namespace at { namespace native {

namespace {

static const int WARP_SIZE = 32;
static const int BLOCKDIMY = 32;

template
  <typename scalar_t,
   typename accscalar_t>
__global__ void embedding_backward_feature_kernel
  (int64_t* indices,
   const scalar_t* __restrict__ grad,
   scalar_t* __restrict__ grad_weight,
   int n, // OK to pass as int, we don't expect 2 billion+ samples in one shot
   int64_t stride,
   int padding_idx)
{
  extern __shared__ char buf[];
  accscalar_t* smem = (accscalar_t*)buf;
  accscalar_t* my_s = smem + WARP_SIZE*threadIdx.y;
  int* indices_batch = (int*)(buf + sizeof(accscalar_t)*WARP_SIZE*blockDim.y);

  const int s = (int)stride; // OK to make int, we don't expect 2 billion+ embedding row size

  const int f = threadIdx.x + blockIdx.x*blockDim.x; // feature_dim

  for(int batch_start = 0; batch_start < n; batch_start += blockDim.x*blockDim.y)
  {
    // Entire block cooperates to load a batch of 1024 indices to process
    int tid = threadIdx.x + threadIdx.y*blockDim.x;
    if(batch_start + tid < n)
      indices_batch[tid] = (int)indices[batch_start + tid];

    // Loop over the batch of <= 1024 loaded indices in chunks of blockDim.y = 32
    for(int chunk_start = batch_start; chunk_start < n; chunk_start += blockDim.y)
    {
      // This does double duty:  it makes sure indices_batch is ready, and it makes sure match-group
      // leaders are done with their accumulates before other warps start loading again.
      __syncthreads();

      int n_this_chunk = (n - chunk_start) < blockDim.y ? (n - chunk_start) : blockDim.y;

      int src_row = chunk_start + threadIdx.y;
      int dst_row = indices_batch[src_row - batch_start]; // This warp's target row in grad_weight

      // All warps load their smem segments with incoming grad data
      if(src_row < n && f < s && dst_row != padding_idx)
        my_s[threadIdx.x] = static_cast<accscalar_t>(grad[src_row*stride + f]);

      __syncthreads();

      // To ensure determinism, we can't just have each warp add its grad data to its dst_row.
      // We need to check if any other warps pulled grad data targeting dst_row.
      // If so, we elect the first warp in each matching group as the leader.
      // Each leader warp serializes the accumulates targeting dst_row in shared memory,
      // then finishes by adding the accumulated buffer to dst_row in grad_weight.
      if(dst_row != padding_idx && src_row < n) // Per-warp exit condition, safe with ballot_sync
      {
        int match_found_this_thread =
          (dst_row == indices_batch[chunk_start - batch_start + threadIdx.x]);
        if(threadIdx.x >= n_this_chunk)
          match_found_this_thread = 0;
        unsigned int matchmask = WARP_BALLOT(match_found_this_thread);

        int first_remaining_peer = __ffs(matchmask) - 1;

        if(threadIdx.y == first_remaining_peer) // Nominate lowest-indexed warp as the leader
        {
          matchmask ^= (1 << first_remaining_peer);
          while(matchmask)
          {
            first_remaining_peer = __ffs(matchmask) - 1;
            my_s[threadIdx.x] += smem[threadIdx.x + WARP_SIZE*first_remaining_peer];
            matchmask ^= (1 << first_remaining_peer);
          }
          if(f < s)
            grad_weight[dst_row*stride + f] += static_cast<scalar_t>(my_s[threadIdx.x]);
        }
      }
    }
  }
}


template <typename scalar_t>
__global__ void embedding_backward_kernel(
  int64_t* input, int64_t* indices, scalar_t* grad_output, scalar_t* grad_weight,
  int64_t* count, int64_t numel, int64_t stride, int padding_idx) {

  using accscalar_t = acc_type<scalar_t, true>;
  int idx = blockIdx.x * 4 + threadIdx.y;

  // Each warp is responsible for an input into the LookupTable.
  // If the preceding input has the same as this input, then the warp
  // exits immediately. The warp also processes subsequent inputs with the
  // same value.
  //
  // Input Warp
  // 1     <warp 1>
  // 1     <warp 1> (<warp 2> exits without doing any work)
  // 5     <warp 3>
  // 8     <warp 4>

  // Number of values proceessed by each thread (grain size)
  const int SZ = 4;

  if (idx < numel
      && (idx == 0 || input[idx] != input[idx - 1])
      && input[idx] != padding_idx) {
    do {
      const int start_feature = threadIdx.x + blockIdx.y * blockDim.x * SZ;
      const int weight_row = ((int) input[idx]) * stride;
      const int grad_row = ((int) indices[idx]) * stride;
      const accscalar_t scale = count ? (accscalar_t)1.0 / count[idx] : 1.0;

      accscalar_t gradient[SZ];
      accscalar_t weight[SZ];

      #pragma unroll
      for (int ii = 0; ii < SZ; ii++) {
        int feature_dim = start_feature + ii * WARP_SIZE;
        if (feature_dim < stride) {
          gradient[ii] = static_cast<accscalar_t>(grad_output[grad_row + feature_dim]);
          weight[ii] = static_cast<accscalar_t>(grad_weight[weight_row + feature_dim]);
        }
      }

      #pragma unroll
      for (int ii = 0; ii < SZ; ii++) {
        weight[ii] += gradient[ii] * scale;
      }

      #pragma unroll
      for (int ii = 0; ii < SZ; ii++) {
        int feature_dim = start_feature + ii * WARP_SIZE;
        if (feature_dim < stride) {
            grad_weight[weight_row + feature_dim] = static_cast<scalar_t>(weight[ii]);
        }
      }

      idx++;
    } while (idx < numel && input[idx] == input[idx - 1]);
  }
}

/* Calculate norms of the rows of weight_ptr given by idx_ptr and capture them in norms */
template <typename scalar_t, typename accscalar_t>
__global__ void renorm_kernel(
    scalar_t* weights, int64_t* indices, accscalar_t max_norm,
    accscalar_t norm_type, int dim) {

  // Some casting hacks since dynamic shared memory and templates don't work together:
  extern __shared__ unsigned char smem[];
  auto sdata = reinterpret_cast<accscalar_t*>(smem);

  int tid = threadIdx.x;
  int base_index = indices[blockIdx.x] * dim;

  accscalar_t v = 0;
  for (int i = tid; i < dim; i += blockDim.x) {
    auto x = static_cast<accscalar_t>(weights[base_index + i]);
    if (norm_type == 1) {
      v += std::abs(x);
    } else if (norm_type == 2) {
      v += x * x;
    } else {
      v += std::pow(x, norm_type);
    }
  }

  using Op = ReduceAdd<accscalar_t>;
  v = reduceBlock<accscalar_t>(sdata, blockDim.x, v, Op(), 0);

  if (tid == 0) {
    sdata[0] = std::pow(v, static_cast<accscalar_t>(1.0 / norm_type));
  }
  __syncthreads();

  // now we renormalize the blocks that need it
  if (sdata[0] > max_norm) {
    auto factor = static_cast<scalar_t>(max_norm / (sdata[0] + 1e-7));
    for (int i = tid; i < dim; i += blockDim.x) {
      weights[base_index + i] *= factor;
    }
  }
}

} // anonymous namespace

Tensor embedding_backward_cuda(const Tensor & grad_, const Tensor & indices,
                               int64_t num_weights, int64_t padding_idx,
                               bool scale_grad_by_freq) {
  auto grad_arg = TensorArg(grad_, "grad", 1);
  auto indices_arg = TensorArg(indices, "indices", 1);
  checkScalarType("embedding_backward", indices_arg, kLong);
  checkContiguous("embedding_backward", indices_arg);
  checkSameGPU("embedding_backward", grad_arg, indices_arg);

  auto num_indices = indices.numel();
  auto grad = grad_.contiguous().view({num_indices, grad_.size(-1)});
  auto grad_weight = at::zeros({num_weights, grad_.size(-1)}, grad_.type());

  int64_t stride = grad_weight.stride(0);
  cudaStream_t stream = globalContext().getCurrentCUDAStream();

  if (num_indices <= 768 && !scale_grad_by_freq) {
    dim3 grid(THCCeilDiv(stride, (int64_t)WARP_SIZE));
    dim3 block(WARP_SIZE, BLOCKDIMY);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF
      (grad.type(),
       "embedding_backward",
       [&]
       {
         using accscalar_t = acc_type<scalar_t, true>;
         embedding_backward_feature_kernel<scalar_t, accscalar_t>
           <<<grid,
              block,
              sizeof(accscalar_t)*WARP_SIZE*BLOCKDIMY + sizeof(int)*WARP_SIZE*BLOCKDIMY,
              stream>>>
           (indices.data<int64_t>(),
            grad.data<scalar_t>(),
            grad_weight.data<scalar_t>(),
            num_indices,
            stride,
            padding_idx);
       });

    THCudaCheck(cudaGetLastError());
    return grad_weight;
  }

  auto sorted_indices = indices.type().tensor(indices.sizes());
  auto orig_indices = indices.type().tensor(indices.sizes());
  using device_ptr = thrust::device_ptr<int64_t>;

  // Sort the inputs into sorted with the corresponding indices; we
  // don't need a stable or multidimensional sort, so just use Thrust
  // directly
  {
    sorted_indices.copy_(indices);

    auto allocator = THCThrustAllocator(globalContext().lazyInitCUDA());
    auto policy = thrust::cuda::par(allocator).on(stream);

    // Fill sortedOrigIndices with sequential indices
    auto count_iter = thrust::counting_iterator<int64_t>(0);
    auto orig_data = device_ptr(orig_indices.data<int64_t>());
    thrust::copy(policy, count_iter, count_iter + num_indices, orig_data);

    // Sort; a stable sort is not required
    auto sorted_data = device_ptr(sorted_indices.data<int64_t>());
    thrust::sort_by_key(policy, sorted_data, sorted_data + num_indices, orig_data,
                        ThrustLTOp<int64_t>());
  }

  Tensor count;
  if (scale_grad_by_freq) {
    count = indices.type().tensor(indices.sizes());

    auto allocator = THCThrustAllocator(globalContext().lazyInitCUDA());
    auto policy = thrust::cuda::par(allocator).on(stream);

    // Compute an increasing sequence per unique item in sortedIndices:
    // sorted: 2 5 5 5 7 7 8 9 9
    //  count: 1 1 2 3 1 2 1 1 2
    auto sorted_data = device_ptr(sorted_indices.data<int64_t>());
    auto count_data = device_ptr(count.data<int64_t>());
    thrust::inclusive_scan_by_key(
      policy,
      sorted_data,
      sorted_data + num_indices,
      thrust::make_constant_iterator(1),
      count_data
    );

    // Take the maximum of each count per unique key in reverse:
    // sorted: 2 5 5 5 7 7 8 9 9
    //  count: 1 3 3 3 2 2 1 2 2
    thrust::inclusive_scan_by_key(
      policy,
      thrust::make_reverse_iterator(sorted_data + num_indices),
      thrust::make_reverse_iterator(sorted_data),
      thrust::make_reverse_iterator(count_data + num_indices),
      thrust::make_reverse_iterator(count_data + num_indices),
      thrust::equal_to<int64_t>(),
      thrust::maximum<int64_t>()
    );
  }

  dim3 grid(THCCeilDiv(num_indices, (int64_t) 4), THCCeilDiv(stride, (int64_t) 128));
  dim3 block(32, 4);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(grad.type(), "embedding_backward", [&] {
    embedding_backward_kernel<<<grid, block, 0, stream>>>(
      sorted_indices.data<int64_t>(),
      orig_indices.data<int64_t>(),
      grad.data<scalar_t>(),
      grad_weight.data<scalar_t>(),
      count.defined() ? count.data<int64_t>() : nullptr,
      num_indices,
      stride,
      padding_idx);
  });
  THCudaCheck(cudaGetLastError());

  return grad_weight;
}

Tensor & embedding_renorm_cuda_(Tensor & self, const Tensor & indices,
                                double max_norm, double norm_type) {
  auto self_arg = TensorArg(self, "self", 1);
  auto indices_arg = TensorArg(indices, "indices", 1);
  checkContiguous("embedding_renorm_", self_arg);
  checkContiguous("embedding_renorm", indices_arg);
  checkDim("embedding_renorm_", self_arg, 2);
  checkSameGPU("embedding_renorm", self_arg, indices_arg);

  cudaStream_t stream = globalContext().getCurrentCUDAStream();
  auto allocator = THCThrustAllocator(globalContext().lazyInitCUDA());
  auto policy = thrust::cuda::par(allocator).on(stream);

  using device_ptr = thrust::device_ptr<int64_t>;

  auto num_indices = indices.numel();
  auto indices_data = device_ptr(indices.data<int64_t>());

  // FIXME: thrust::unique only removes consecutive elements that are equal.
  // We have race conditions when indices contain duplicates which are not
  // adjacent
  auto unique_indices = indices.type().tensor(indices.numel());
  auto unique_data = device_ptr(unique_indices.data<int64_t>());
  auto end = thrust::unique_copy(policy, indices_data, indices_data + num_indices, unique_data);
  auto num_unique_indices = static_cast<int>(end - unique_data);

  dim3 grid(num_unique_indices);
  dim3 block(128);
  int dim = self.stride(0);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(self.type(), "embedding_backward", [&] {
    using accscalar_t = acc_type<scalar_t, true>;
    renorm_kernel<<<grid, block, 128 * sizeof(accscalar_t), stream>>>(
      self.data<scalar_t>(),
      unique_indices.data<int64_t>(),
      static_cast<accscalar_t>(max_norm),
      static_cast<accscalar_t>(norm_type),
      dim);
  });
  THCudaCheck(cudaGetLastError());

  return self;
}

}}  // namespace at::native
