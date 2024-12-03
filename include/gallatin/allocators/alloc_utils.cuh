#ifndef GALLATIN_ALLOC_UTILS
#define GALLATIN_ALLOC_UTILS

#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include <cooperative_groups/scan.h>
#include <cuda.h>
#include <cuda_runtime_api.h>

#include "assert.h"
#include "stdio.h"

namespace cg = cooperative_groups;

//using namespace gallatin::allocators;

#ifndef GPUErrorCheck
#define GPUErrorCheck(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}
#endif

// helper_macro
// define macros
#define MAX_VALUE(nbits) ((1ULL << (nbits)) - 1)
#define BITMASK(nbits) ((nbits) == 64 ? 0xffffffffffffffff : MAX_VALUE(nbits))

#define SET_BIT_MASK(index) ((1ULL << index))

// a pointer list managing a set section of device memory
namespace gallatin {

namespace utils {

__device__ inline uint ldca(const uint *p) {
  uint res;
  asm volatile("ld.global.ca.u32 %0, [%1];" : "=r"(res) : "l"(p));
  return res;
}

__device__ inline uint64_t ldca(const uint64_t *p) {
  uint64_t res;
  asm volatile("ld.global.ca.u64 %0, [%1];" : "=l"(res) : "l"(p));
  return res;

  // return atomicOr((unsigned long long int *)p, 0ULL);
}

__device__ inline uint ldcg(const uint *p) {
  uint res;
  asm volatile("ld.global.cg.u32 %0, [%1];" : "=r"(res) : "l"(p));
  return res;
}

__device__ inline int ldcg(const int *p) {
  uint res;
  asm volatile("ld.global.cg.s32 %0, [%1];" : "=r"(res) : "l"(p));
  return res;
}

__device__ inline uint64_t ldcg(const uint64_t *p) {
  uint64_t res;
  asm volatile("ld.global.cg.u64 %0, [%1];" : "=l"(res) : "l"(p));
  return res;

  // return atomicOr((unsigned long long int *)p, 0ULL);
}

__device__ inline uint ldcv(const uint *p) {
  uint res;
  asm volatile("ld.global.cv.u32 %0, [%1];" : "=r"(res) : "l"(p));
  return res;
}

__device__ inline int ldcv(const int *p) {
  uint res;
  asm volatile("ld.global.cv.s32 %0, [%1];" : "=r"(res) : "l"(p));
  return res;
}

__device__ inline uint64_t ldcv(const uint64_t *p) {
  uint64_t res;
  asm volatile("ld.global.cv.u64 %0, [%1];" : "=l"(res) : "l"(p));
  return res;

  // return atomicOr((unsigned long long int *)p, 0ULL);
}

__device__ inline uint16_t ldcv(const uint16_t *p) {
  uint16_t res;
  asm volatile("ld.global.cv.u16 %0, [%1];" : "=h"(res) : "l"(p));
  return res;
}


__device__ inline uint64_t ld_acq(const uint64_t *p) {
  uint64_t res;
  asm volatile("ld.gpu.acquire.u64 %0, [%1];" : "=l"(res) : "l"(p));
  return res;

  // return atomicOr((unsigned long long int *)p, 0ULL);
}

__device__ inline uint16_t ld_acq(const uint16_t *p) {
  uint16_t res;
  asm volatile("ld.gpu.acquire.u16 %0, [%1];" : "=h"(res) : "l"(p));
  return res;
}


__device__ inline void st_rel(const uint64_t *p, uint64_t store_val) {
  
  asm volatile("st.gpu.release.u64 [%0], %1;" :: "l"(p), "l"(store_val) : "memory");

  // return atomicOr((unsigned long long int *)p, 0ULL);
}





__device__ inline uint16_t global_read_uint16_t(const uint16_t *p) {
  uint16_t res;
  asm volatile("ld.global.ca.u16 %0, [%1];" : "=h"(res) : "l"(p));
  return res;
}

//this does not guarantee visibility to other threads.=
__device__ inline void global_store_byte(const char *p, char byte) {
 
  asm volatile("st.global.wb.u8 [%0], %1;" :: "l"(p), "h"((uint16_t) byte));
  
  return;
}


__device__ inline void *ldca(void *const *p) {
  void *res;
  asm volatile("ld.global.ca.u64 %0, [%1];" : "=l"(res) : "l"(p));
  return res;
}


//given a target and new pointer, make target point to new.
template <typename T>
__device__ inline void swap_to_new_array(T *& target, T *& new_ptr){

  atomicExch((unsigned long long int *)&target, (unsigned long long int)new_ptr);

}

//this doesn't work. not sure why, something gets converted to local * space
// and then the .global fails.
// template <typename T>
// __device__ inline T *global_load_array_ptr(T * p) {


//   const uint64_t * p_addr_as_uint64_t  = (uint64_t *) &p;
//   uint64_t res;
//   asm volatile("ld.global.ca.u64 %0, [%1];" : "=l"(res) : "l"(p_addr_as_uint64_t));
//   return (T *) res;
// }

/** prefetches into L1 cache */
__device__ inline void prefetch_l1(const void *p) {
  asm("prefetch.global.L1 [%0];" : : "l"(p));
}

/** prefetches into L2 cache */
__device__ inline void prefetch_l2(const void *p) {
  asm("prefetch.global.L2 [%0];" : : "l"(p));
}

/** get clock time in ns **/
__device__ inline uint64_t get_clock_time() {
  uint64_t res;
  asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(res));

  return res;
}

__device__ inline uint get_smid() {
  uint ret;

  asm("mov.u32 %0, %smid;" : "=r"(ret));

  return ret;
}

__host__ inline int get_num_streaming_multiprocessors(int which_device) {
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, which_device);
  int mp = prop.multiProcessorCount;

  return mp;
}

// for a given template family, how many chunks do they need?
template <uint64_t bytes_per_chunk>
__host__ inline uint64_t get_max_chunks() {
  size_t mem_total;
  size_t mem_free;
  cudaMemGetInfo(&mem_free, &mem_total);

  return mem_total / bytes_per_chunk;
}

__host__ inline void print_mem_in_use() {
  size_t mem_total;
  size_t mem_free;
  cudaMemGetInfo(&mem_free, &mem_total);

  size_t bytes_in_use = mem_total - mem_free;
  printf("%lu/%lu bytes used\n", bytes_in_use, mem_total);
}

template <uint64_t bytes_per_chunk>
__host__ inline uint64_t get_max_chunks(uint64_t max_bytes) {
  return max_bytes / bytes_per_chunk;
}

template <typename Struct_Type>
__host__ inline Struct_Type *get_host_version() {
  Struct_Type *host_version;

  cudaMallocHost((void **)&host_version, sizeof(Struct_Type));

  return host_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *get_host_version(uint64_t num_copies) {
  Struct_Type *host_version;

  cudaMallocHost((void **)&host_version, num_copies * sizeof(Struct_Type));

  return host_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *get_device_version() {
  Struct_Type *dev_version;

  cudaMalloc((void **)&dev_version, sizeof(Struct_Type));

  return dev_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *get_device_version(uint64_t num_copies) {
  Struct_Type *dev_version;

  cudaMalloc((void **)&dev_version, num_copies * sizeof(Struct_Type));

  return dev_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_device(Struct_Type *host_version) {
  Struct_Type *dev_version = get_device_version<Struct_Type>();

  cudaMemcpy(dev_version, host_version, sizeof(Struct_Type),
             cudaMemcpyHostToDevice);

  cudaDeviceSynchronize();

  cudaFreeHost(host_version);

  return dev_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_host(Struct_Type *dev_version) {
  Struct_Type *host_version = get_host_version<Struct_Type>();

  cudaMemcpy(host_version, dev_version, sizeof(Struct_Type),
             cudaMemcpyDeviceToHost);

  cudaDeviceSynchronize();

  cudaFree(dev_version);

  return host_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_device(Struct_Type *host_version,
                                     uint64_t num_copies) {
  // printf("Starting copy\n");

  Struct_Type *dev_version = get_device_version<Struct_Type>(num_copies);

  // printf("Dev ptr %lx\n", (uint64_t) dev_version);

  cudaMemcpy(dev_version, host_version, num_copies * sizeof(Struct_Type),
             cudaMemcpyHostToDevice);

  cudaDeviceSynchronize();

  cudaFreeHost(host_version);

  return dev_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_host(Struct_Type *dev_version,
                                   uint64_t num_copies) {
  Struct_Type *host_version = get_host_version<Struct_Type>(num_copies);

  cudaMemcpy(host_version, dev_version, num_copies * sizeof(Struct_Type),
             cudaMemcpyDeviceToHost);

  cudaDeviceSynchronize();

  cudaFree(dev_version);

  return host_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_device_nowait(Struct_Type *host_version) {
  Struct_Type *dev_version = get_device_version<Struct_Type>();

  cudaMemcpy(dev_version, host_version, sizeof(Struct_Type),
             cudaMemcpyHostToDevice);


  cudaFreeHost(host_version);

  return dev_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *move_to_device_nowait(Struct_Type *host_version,
                                     uint64_t num_copies) {
  // printf("Starting copy\n");

  Struct_Type *dev_version = get_device_version<Struct_Type>(num_copies);

  // printf("Dev ptr %lx\n", (uint64_t) dev_version);

  cudaMemcpy(dev_version, host_version, num_copies * sizeof(Struct_Type),
             cudaMemcpyHostToDevice);

  cudaFreeHost(host_version);

  return dev_version;
}


template <typename Struct_Type>
__host__ inline Struct_Type *copy_to_host(Struct_Type *dev_version,
                                   uint64_t num_copies) {
  Struct_Type *host_version = get_host_version<Struct_Type>(num_copies);

  cudaMemcpy(host_version, dev_version, num_copies * sizeof(Struct_Type),
             cudaMemcpyDeviceToHost);

  cudaDeviceSynchronize();

  return host_version;
}

template <typename Struct_Type>
__host__ inline Struct_Type *copy_to_host(Struct_Type *dev_version) {
  Struct_Type *host_version = get_host_version<Struct_Type>();

  cudaMemcpy(host_version, dev_version, sizeof(Struct_Type),
             cudaMemcpyDeviceToHost);

  cudaDeviceSynchronize();

  return host_version;
}

static __host__ __device__ inline int get_first_bit_bigger(uint64_t counter) {
  //	if (__builtin_popcountll(counter) == 1){

  // 0th bit would give 63

  // 63rd bit would give 0

#ifndef __CUDA_ARCH__

  return 63 - __builtin_clzll(counter) + (__builtin_popcountll(counter) != 1);

#else

  return 63 - __clzll(counter) + (__popcll(counter) != 1);

#endif
}

__device__ inline uint64_t get_tid() {
  return ((uint64_t)threadIdx.x) + ((uint64_t)blockIdx.x) * ((uint64_t) blockDim.x);
}


template <typename team_type>
__device__ inline uint64_t get_tile_tid(team_type team) {


  return ((uint64_t) team.meta_group_rank()) + ((uint64_t)blockIdx.x) * ((uint64_t) team.meta_group_size());

}

template <uint team_size>
__device__ inline uint64_t get_team_tid(cg::thread_block_tile<team_size> team) {

  uint64_t block_id = blockIdx.x;

  uint64_t team_id = team.meta_group_rank();

  uint64_t team_meta_size = team.meta_group_size();

  return team_id + team_meta_size*block_id;

}

__device__ inline void cooperative_copy(char *dst, char *src, uint64_t num_bytes) {
  for (uint64_t i = threadIdx.x; i < num_bytes; i += blockDim.x) {
    dst[i] = src[i];
  }
}

template <typename T>
__device__ inline void cooperative_copy(T *dst, T *src) {
  return cooperative_copy((char *)dst, (char *)src, sizeof(T));
}


//count first contiguous - ll variant
//return # of contiguous 1s present in lower order bits
__device__ inline int __cfcll(uint64_t bits){


  int popc = __popcll(bits);

  bool popc_valid = popc == 0 || popc == 64;

  //branchless if-else cause we like pain
  //if popc 0, whole vector zero, #contiguous is 0
  //

  return (popc)*(popc_valid) + (__ffsll(~bits)-1)*(!popc_valid);

}



#if GALLATIN_USING_DYNAMIC_PARALLELISM

__device__ inline void clear_memory_per_thread(void * memory, uint64_t num_bytes, uint64_t n_threads, uint64_t tid){

  uint64_t bytes_per_thread = (num_bytes-1)/n_threads+1;

  uint64_t my_start = bytes_per_thread*tid;

  uint64_t my_length = num_bytes;

  //this thread responsible for weird offset at end.
  if ((my_start + my_length) >= num_bytes) my_length = num_bytes-my_start;

  if (my_length == 0 || my_start >= num_bytes) return;

  memset( ((char *) memory)+my_start, 0, my_length);

  __threadfence();

  return;


}


__global__ inline void clear_memory_kernel(void * memory, uint64_t num_bytes, uint64_t num_threads){

  uint64_t tid = gallatin::utils::get_tid();

  clear_memory_per_thread(memory, num_bytes, num_threads, tid);

}



// template <typename gallatin_template_type>
// __global__ inline void calloc_return_block 


// //two templates for dynamic parallelism - these are launched by an internal func in Gallatin
// // and sidestep the regular free for callocs.
// template <typename gallatin_template_type>
// __global__ inline void gallatin_clear_block(void * memory, uint64_t num_bytes, uint64_t n_threads, gallatin_template_type * allocator){

//   uint64_t tid = gallatin::utils::get_tid();

//   clear_memory_per_thread(memory, num_bytes, num_threads, tid);
  


// }

template <typename gallatin_template_type, typename block_type>
__global__ inline void calloc_return_block(gallatin_template_type * allocator, block_type * block_to_free, uint64_t segment, uint16_t tree){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid != 0) return;

  allocator->return_block(block_to_free, segment, tree);


}


//template <typename gallatin_template_type>
__global__ inline void test_kernel (int test_value) {

  uint64_t tid = gallatin::utils::get_tid();

  if (tid == 0) printf("Test kernel launch\n");

  return;

}


//two templates for dynamic parallelism - these are launched by an internal func in Gallatin
// and sidestep the regular free for callocs.
template <typename gallatin_template_type, typename block_type>
__global__ inline void gallatin_clear_block(block_type * block, void * memory, uint64_t num_bytes, uint64_t num_threads, gallatin_template_type * allocator, uint64_t segment, uint16_t tree){



  return; 


  uint64_t tid = gallatin::utils::get_tid();

  if (tid >= num_threads) return;

  clear_memory_per_thread(memory, num_bytes, num_threads, tid);
  

  if (tid == 0){

    calloc_return_block<gallatin_template_type, block_type><<<1,1, 0, cudaStreamTailLaunch>>>(allocator, block, segment, tree);

  }


}


template <typename gallatin_template_type>
__global__ inline void calloc_return_segment(gallatin_template_type * allocator, uint64_t segment, uint16_t size, uint16_t tree_id){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid != 0) return;

  allocator->submit_segment_for_free(segment, size, tree_id);


}


//two templates for dynamic parallelism - these are launched by an internal func in Gallatin
// and sidestep the regular free for callocs.
template <typename gallatin_template_type>
__global__ inline void gallatin_clear_segment(void * memory, uint64_t num_bytes, uint64_t num_threads, gallatin_template_type * allocator, uint64_t segment, uint16_t size, uint16_t tree_id){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid >= num_threads) return;

  clear_memory_per_thread(memory, num_bytes, num_threads, tid);
  

  if (tid == 0){

    calloc_return_segment<gallatin_template_type><<<1,1,0,cudaStreamTailLaunch>>>(allocator, segment, size, tree_id);

  }


}


  
//use dynamic parallelism to clear memory
__device__ inline void memclear_generic(void * memory, uint64_t num_bytes, uint64_t num_threads){

  clear_memory_kernel<<<((num_threads-1)/512 +1), 512>>>(memory, num_bytes, num_threads);

}


template <typename T>
__device__ inline void memclear(T * memory, uint64_t nitems, uint64_t nthreads){

  memclear_generic((void *)memory, sizeof(T)*nitems, nthreads);
}

#endif


constexpr uint64_t numberOfBits(uint64_t x)
{
    return x < 2 ? x : 1+numberOfBits(x >> 1);
}


__device__ inline void clear_host_memory_per_thread(void * memory, uint64_t num_bytes, uint64_t n_threads, uint64_t tid){

  uint64_t bytes_per_thread = (num_bytes-1)/n_threads+1;

  uint64_t my_start = bytes_per_thread*tid;

  uint64_t my_length = num_bytes;

  //this thread responsible for weird offset at end.
  if ((my_start + my_length) >= num_bytes) my_length = num_bytes-my_start;

  if (my_length == 0 || my_start >= num_bytes) return;

  memset( ((char *) memory)+my_start, 0, my_length);

  __threadfence();

  return;


}


__global__ inline void clear_host_memory_kernel(void * memory, uint64_t num_bytes, uint64_t num_threads){

  uint64_t tid = gallatin::utils::get_tid();

  clear_host_memory_per_thread(memory, num_bytes, num_threads, tid);

}


__host__ inline void clear_device_host_memory(void * ptr, uint64_t num_bytes){

  uint64_t num_threads = (num_bytes-1)/16+1;

  clear_host_memory_kernel<<<(num_threads-1)/512+1,512>>>(ptr, num_bytes, num_threads);

}


}  // namespace utils

}  // namespace gallatin

#endif  // GPU_BLOCK_