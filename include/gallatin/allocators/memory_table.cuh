#ifndef GALLATIN_MEMORY_TABLE
#define GALLATIN_MEMORY_TABLE
// A CUDA implementation of the alloc table, made by Hunter McCoy
// (hunter@cs.utah.edu) Copyright (C) 2023 by Hunter McCoy

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without l> imitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so,
//  subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial
//  portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
//  IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

// The alloc table is an array of uint64_t, uint64_t pairs that store

// inlcudes
#include <cuda.h>
#include <cuda_runtime_api.h>

#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <gallatin/allocators/alloc_utils.cuh>
#include <gallatin/allocators/block.cuh>
#include <gallatin/allocators/veb.cuh>
#include <gallatin/allocators/murmurhash.cuh>


//This locks the ability of blocks to be returned to the system.
//so blocks accumulate as normal, but segments are not recycled.
//used to test consistency
#define DEBUG_NO_FREE 0

#define GALLATIN_MEM_TABLE_DEBUG 0

#define GALLATIN_TABLE_GLOBAL_READ 1


//how many bytes per thread a memclear needs to operate on
#define GALLATIN_MEMCLEAR_SIZE 1

namespace gallatin {

namespace allocators {


enum Gallatin_memory_type {device_only, host_only, managed};


//get the total # of allocs freed in the system.
//max # blocks - this says something about the current state
template <typename table>
__global__ inline void count_block_free_kernel(table * alloc_table, uint64_t num_blocks, uint64_t * counter){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid >= num_blocks) return;

  uint64_t fill = alloc_table->blocks[tid].free_counter;

  atomicAdd((unsigned long long int *)counter, fill);


}


template <typename table>
__global__ inline void count_block_live_kernel(table * alloc_table, uint64_t num_blocks, uint64_t * counter){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid >= num_blocks) return;

  uint64_t merged_fill = alloc_table->blocks[tid].malloc_counter;

  uint64_t fill = alloc_table->blocks[tid].clip_count(merged_fill);

  if (fill > 4096) fill = 4096;

  atomicAdd((unsigned long long int *)counter, fill);


}

#if GALLATIN_USING_DYNAMIC_PARALLELISM

//kernel called to actually clear memory.
template <typename allocator_type, typename block_type>
__global__ inline void clear_block_memory_kernel(allocator_type * allocator, uint64_t segment, uint64_t size, uint64_t num_blocks, uint queue_start, int live_blocks, uint16_t tree_id){


  uint64_t tid = gallatin::utils::get_tid();

  //if (tid == 0) printf("Clearing segment %llu\n", segment);

  uint64_t threads_per_block = (size*4096-1)/GALLATIN_MEMCLEAR_SIZE+1;

  uint64_t threads_needed = threads_per_block*live_blocks;

  if (tid >= threads_needed) return;


  uint64_t my_block = tid/threads_per_block;

  uint64_t my_offset = tid % threads_per_block;

  if (my_block >= live_blocks) return;

  //read my block and determine my memory

  uint64_t my_address = (my_block + queue_start) % num_blocks;

  uint64_t base_offset = allocator->table->blocks_per_segment * segment;

  block_type * my_block_ptr = (block_type *) atomicCAS((unsigned long long int *)&allocator->table->calloc_queues[base_offset + my_address], 0ULL, 0ULL);

  uint64_t block_id = allocator->table->get_global_block_offset(my_block_ptr);

  if (my_offset == 0){

    //printf("Thread %llu returning block %llu (%llx) to segment %llu\n", tid, block_id, my_block_ptr, segment);
    allocator->return_block(my_block_ptr, segment, tree_id);
  }


}

//given kernel, one thread determines # of blocks to handle
//then launch child kernel
template <typename allocator_type, typename block_type>
__global__ inline void setup_clear_blocks_kernel(allocator_type * allocator, uint64_t segment, uint64_t size, uint64_t num_blocks, uint16_t tree_id){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid != 0) return;

  //printf("kernel for stream %llu\n", segment);

  int num_live_blocks = atomicExch(&allocator->table->calloc_counters[segment], 0);

  //then add to my counter
  uint my_start = atomicAdd(&allocator->table->calloc_clear_counters[segment], num_live_blocks);

  uint64_t threads_per_block = (size*4096-1)/GALLATIN_MEMCLEAR_SIZE+1;

  uint64_t threads_needed = threads_per_block*num_live_blocks;

  clear_block_memory_kernel<allocator_type, block_type><<<(threads_needed-1)/256+1, 256, 0, cudaStreamFireAndForget>>>(allocator, segment, size, num_blocks, my_start, num_live_blocks, tree_id);


}

#endif

// alloc table associates chunks of memory with trees
// using uint16_t as there shouldn't be that many trees.
// register atomically insert tree num, or registers memory from chunk_tree.

__global__ inline void gallatin_init_counters_kernel(
                                           int * active_counts,
                                           uint * queue_counters, uint * queue_free_counters,
                                           uint * final_queue_free_counters,
                                           Block *blocks, Block ** queues, uint64_t num_segments,
                                           uint64_t blocks_per_segment) {
  uint64_t tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid >= num_segments) return;

  active_counts[tid] = -1;

  queue_counters[tid] = 0;
  queue_free_counters[tid] = 0;
  final_queue_free_counters[tid] = 0;

  uint64_t base_offset = blocks_per_segment * tid;

  for (uint64_t i = 0; i < blocks_per_segment; i++) {
    Block *my_block = &blocks[base_offset + i];

    my_block->init();

    queues[base_offset+i] = nullptr;

  }

  __threadfence();
}


__global__ inline void init_calloc_counters_kernel(int * calloc_active_counters, uint * calloc_enqueue_counters, uint * calloc_finished_counters, Block ** calloc_queues, uint * calloc_clear_counters, uint64_t num_segments, uint64_t blocks_per_segment){

  uint64_t tid = gallatin::utils::get_tid();

  if (tid >= num_segments) return;


  calloc_active_counters[tid] = 0;
  calloc_enqueue_counters[tid] = 0;
  calloc_finished_counters[tid] = 0;

  calloc_clear_counters[tid] = 0;

  uint64_t base_offset = blocks_per_segment * tid;

  for (uint64_t i = 0; i < blocks_per_segment; i++){

    calloc_queues[base_offset + i] = nullptr;

  }

}

// The alloc table owns all blocks live in the system
// and information for each segment
template <uint64_t bytes_per_segment, uint64_t min_size>
struct alloc_table {
  using my_type = alloc_table<bytes_per_segment, min_size>;

  // the tree id of each chunk
  uint16_t *chunk_ids;

  // list of all blocks live in the system.
  Block *blocks;

  //queues hold freed blocks for fast turnaround
  Block ** queues;

  //queue counters record position in queue
  uint * queue_counters;

  //free counters holds which index newly freed blocks are emplaced.
  uint * queue_free_counters;

  uint * final_queue_free_counters;

  //active counts make sure that the # of blocks in movement are acceptable.
  int * active_counts;


  // all memory live in the system.
  char *memory;

  uint64_t num_segments;

  uint64_t blocks_per_segment;

  Gallatin_memory_type memory_control;

  //additional controls for calloc

  bool calloc_mode;

  int * calloc_counters;

  uint * calloc_enqueue_position;

  uint * calloc_clear_counters;

  //CAS is necessary for correctness.
  uint * calloc_enqueue_finished;

  Block ** calloc_queues;

  #if GALLATIN_USING_DYNAMIC_PARALLELISM

  cudaStream_t * streams;

  #endif

  //optional helper kernels.
  //cudaStream_t * free_streams;


  // generate structure on device and return pointer.
  static __host__ inline my_type *generate_on_device(uint64_t max_bytes,  Gallatin_memory_type ext_memory_control=device_only, bool calloc=false) {
    my_type *host_version;

    cudaMallocHost((void **)&host_version, sizeof(my_type));

    uint64_t num_segments =
        gallatin::utils::get_max_chunks<bytes_per_segment>(max_bytes);

    //printf("Booting memory table with %llu chunks\n", num_segments);

    uint16_t *ext_chunks;

    cudaMalloc((void **)&ext_chunks, sizeof(uint16_t) * num_segments);

    cudaMemset(ext_chunks, ~0U, sizeof(uint16_t) * num_segments);

    host_version->chunk_ids = ext_chunks;

    host_version->num_segments = num_segments;

    // init blocks

    uint64_t blocks_per_segment = bytes_per_segment / (min_size * 4096);

    Block *ext_blocks;

    cudaMalloc((void **)&ext_blocks,
             sizeof(Block) * blocks_per_segment * num_segments);

    cudaMemset(ext_blocks, 0U,
               sizeof(Block) * (num_segments * blocks_per_segment));

    host_version->blocks = ext_blocks;

    host_version->blocks_per_segment = blocks_per_segment;


    Block ** ext_queues;
    cudaMalloc((void **)&ext_queues, sizeof(Block *)*blocks_per_segment*num_segments);

    host_version->queues = ext_queues;


    if (ext_memory_control == device_only){

      host_version->memory = gallatin::utils::get_device_version<char>(
        bytes_per_segment * num_segments);

      cudaMemset(host_version->memory, 0, bytes_per_segment*num_segments);


    } else if (ext_memory_control == host_only){

      char * host_memory;
      char * dev_ptr_host_memory;

      cudaDeviceProp prop;
      GPUErrorCheck(cudaGetDeviceProperties(&prop, 0));
      if (!prop.canMapHostMemory)
      {
          throw std::runtime_error{"Device does not supported mapped memory."};
      }

      GPUErrorCheck(cudaHostAlloc((void **)&host_memory, bytes_per_segment*num_segments, cudaHostAllocMapped));


      //GPUErrorCheck(cudaHostAlloc((void **)&host_memory, bytes_per_segment*num_segments, cudaHostAllocDefault));

      //memset(host_memory, 0, bytes_per_segment*num_segments);

      CHECK_CUDA_ERROR(cudaHostGetDevicePointer(&dev_ptr_host_memory, host_memory, 0));

      //cudaMemset(dev_ptr_host_memory, 0, bytes_per_segment*num_segments);

      gallatin::utils::clear_device_host_memory(dev_ptr_host_memory, bytes_per_segment*num_segments);

      host_version->memory = dev_ptr_host_memory;

    } else if (ext_memory_control == managed) {


      char * host_memory;

      cudaMallocManaged((void **)&host_memory, bytes_per_segment*num_segments);

      cudaMemset(host_memory, 0, bytes_per_segment*num_segments);

      host_version->memory = host_memory;


    }



    // generate counters and set them to 0.
    host_version->active_counts = gallatin::utils::get_device_version<int>(num_segments);

    host_version->queue_counters = gallatin::utils::get_device_version<uint>(num_segments);
    host_version->queue_free_counters = gallatin::utils::get_device_version<uint>(num_segments);
    host_version->final_queue_free_counters = gallatin::utils::get_device_version<uint>(num_segments);



    gallatin_init_counters_kernel<<<(num_segments - 1) / 512 + 1, 512>>>(
        host_version->active_counts, 
        host_version->queue_counters, host_version->queue_free_counters,
        host_version->final_queue_free_counters,
        host_version->blocks, host_version->queues, num_segments,
        blocks_per_segment);


    if (calloc){


      host_version->calloc_mode = true;
      host_version->calloc_counters = gallatin::utils::get_device_version<int>(num_segments);
      host_version->calloc_enqueue_position = gallatin::utils::get_device_version<uint>(num_segments);
      host_version->calloc_enqueue_finished = gallatin::utils::get_device_version<uint>(num_segments);
      host_version->calloc_clear_counters = gallatin::utils::get_device_version<uint>(num_segments);


      Block ** ext_calloc_queues;
      cudaMalloc((void **)&ext_calloc_queues, sizeof(Block *)*blocks_per_segment*num_segments);

      host_version->calloc_queues = ext_calloc_queues;

      init_calloc_counters_kernel<<<(num_segments - 1) / 512 + 1, 512>>>(
        host_version->calloc_counters,
        host_version->calloc_enqueue_position,
        host_version->calloc_enqueue_finished,
        host_version->calloc_queues,
        host_version->calloc_clear_counters,
        num_segments, blocks_per_segment
      );


      #if GALLATIN_USING_DYNAMIC_PARALLELISM

      cudaStream_t * ext_streams = gallatin::utils::get_host_version<cudaStream_t>(num_segments);

      for (uint64_t i = 0; i < num_segments; i++){

        GPUErrorCheck(cudaStreamCreateWithFlags(&ext_streams[i], cudaStreamNonBlocking));

      }

      cudaDeviceSynchronize();

      host_version->streams = gallatin::utils::move_to_device<cudaStream_t>(ext_streams, num_segments);



      #endif


    }


    GPUErrorCheck(cudaDeviceSynchronize());


   



    // move to device and free host memory.
    my_type *dev_version;

    cudaMalloc((void **)&dev_version, sizeof(my_type));

    cudaMemcpy(dev_version, host_version, sizeof(my_type),
               cudaMemcpyHostToDevice);

    cudaDeviceSynchronize();

    cudaFreeHost(host_version);

    return dev_version;
  }


    // generate structure on device and return pointer.
  static __host__ inline my_type *generate_on_device_nowait(uint64_t max_bytes, Gallatin_memory_type ext_memory_control=device_only, bool calloc=false) {
    my_type *host_version;

    cudaMallocHost((void **)&host_version, sizeof(my_type));

    uint64_t num_segments =
        gallatin::utils::get_max_chunks<bytes_per_segment>(max_bytes);

    //printf("Booting memory table with %llu chunks\n", num_segments);

    uint16_t *ext_chunks;

    cudaMalloc((void **)&ext_chunks, sizeof(uint16_t) * num_segments);

    cudaMemset(ext_chunks, ~0U, sizeof(uint16_t) * num_segments);

    host_version->chunk_ids = ext_chunks;

    host_version->num_segments = num_segments;

    // init blocks

    uint64_t blocks_per_segment = bytes_per_segment / (min_size * 4096);

    Block *ext_blocks;

    cudaMalloc((void **)&ext_blocks,
               sizeof(Block) * blocks_per_segment * num_segments);

    cudaMemset(ext_blocks, 0U,
               sizeof(Block) * (num_segments * blocks_per_segment));

    host_version->blocks = ext_blocks;

    host_version->blocks_per_segment = blocks_per_segment;


    Block ** ext_queues;
    cudaMalloc((void **)&ext_queues, sizeof(Block *)*blocks_per_segment*num_segments);

    host_version->queues = ext_queues;

    if (ext_memory_control == device_only){

      host_version->memory = gallatin::utils::get_device_version<char>(
        bytes_per_segment * num_segments);

      cudaMemset(host_version->memory, 0, bytes_per_segment*num_segments);


    } else if (ext_memory_control == host_only){

      char * host_memory;
      char * dev_ptr_host_memory;

      cudaDeviceProp prop;
      GPUErrorCheck(cudaGetDeviceProperties(&prop, 0));
      if (!prop.canMapHostMemory)
      {
          throw std::runtime_error{"Device does not supported mapped memory."};
      }

      //GPUErrorCheck(cudaHostAlloc((void **)&host_memory, bytes_per_segment*num_segments, cudaHostAllocDefault));

      GPUErrorCheck(cudaHostAlloc((void **)&host_memory, bytes_per_segment*num_segments, cudaHostAllocMapped));

      memset(host_memory, 0, bytes_per_segment*num_segments);

      CHECK_CUDA_ERROR(cudaHostGetDevicePointer(&dev_ptr_host_memory, host_memory, 0));

      host_version->memory = dev_ptr_host_memory;

    } else if (ext_memory_control == managed) {


      char * host_memory;

      cudaMallocManaged((void **)&host_memory, bytes_per_segment*num_segments);

      cudaMemset(host_memory, 0, bytes_per_segment*num_segments);

      host_version->memory = host_memory;


    }

    host_version->memory_control = ext_memory_control;

    // generate counters and set them to 0.
    host_version->active_counts = gallatin::utils::get_device_version<int>(num_segments);

    host_version->queue_counters = gallatin::utils::get_device_version<uint>(num_segments);
    host_version->queue_free_counters = gallatin::utils::get_device_version<uint>(num_segments);
    host_version->final_queue_free_counters = gallatin::utils::get_device_version<uint>(num_segments);

    gallatin_init_counters_kernel<<<(num_segments - 1) / 512 + 1, 512>>>(
        host_version->active_counts, 
        host_version->queue_counters, host_version->queue_free_counters,
        host_version->final_queue_free_counters,
        host_version->blocks, host_version->queues, num_segments,
        blocks_per_segment);

    //GPUErrorCheck(cudaDeviceSynchronize());


   
    if (calloc){
      
      printf("\033[1;31mWarning: Calloc is experimental. Performance and correctness are not guaranteed\033[0m\n");

      //uint * calloc_counters;

      //uint * enqueue_position;

      //Block ** calloc_queues;


      host_version->calloc_mode = true;
      host_version->calloc_counters = gallatin::utils::get_device_version<int>(num_segments);
      host_version->calloc_enqueue_position = gallatin::utils::get_device_version<uint>(num_segments);
      host_version->calloc_enqueue_finished = gallatin::utils::get_device_version<uint>(num_segments);
      host_version->calloc_clear_counters = gallatin::utils::get_device_version<uint>(num_segments);




      Block ** ext_calloc_queues;
      cudaMalloc((void **)&ext_calloc_queues, sizeof(Block *)*blocks_per_segment*num_segments);

      host_version->calloc_queues = ext_calloc_queues;

      init_calloc_counters_kernel<<<(num_segments - 1) / 512 + 1, 512>>>(
        host_version->calloc_counters,
        host_version->calloc_enqueue_position,
        host_version->calloc_enqueue_finished,
        host_version->calloc_queues,
        host_version->calloc_clear_counters,
        num_segments, blocks_per_segment
      );

       #if GALLATIN_USING_DYNAMIC_PARALLELISM

      cudaStream_t * ext_streams = gallatin::utils::get_host_version<cudaStream_t>(num_segments);

      for (uint64_t i = 0; i < num_segments; i++){

        GPUErrorCheck(cudaStreamCreateWithFlags(&ext_streams[i], cudaStreamNonBlocking));

      }

      cudaDeviceSynchronize();

      host_version->streams = gallatin::utils::move_to_device<cudaStream_t>(ext_streams, num_segments);



      #endif


    }



    // move to device and free host memory.
    my_type *dev_version;

    cudaMalloc((void **)&dev_version, sizeof(my_type));

    cudaMemcpy(dev_version, host_version, sizeof(my_type),
               cudaMemcpyHostToDevice);

    //cudaDeviceSynchronize();

    cudaFreeHost(host_version);

    return dev_version;
  }

  // return memory/resources to GPU
  static __host__ inline void free_on_device(my_type *dev_version) {
    my_type *host_version;

    cudaMallocHost((void **)&host_version, sizeof(my_type));

    cudaMemcpy(host_version, dev_version, sizeof(my_type),
               cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    #if GALLATIN_USING_DYNAMIC_PARALLELISM

    if (host_version->calloc_mode){

      cudaFree(host_version->calloc_counters);
      cudaFree(host_version->calloc_enqueue_position);
      cudaFree(host_version->calloc_enqueue_finished);

      //free cudastreams

      cudaStream_t * host_streams = gallatin::utils::move_to_host<cudaStream_t>(host_version->streams, host_version->num_segments);
      
      for (uint64_t i = 0; i < host_version->num_segments; i++){
        cudaStreamDestroy (host_streams[i]);
      }
        
      cudaFreeHost(host_streams);

    }

    #endif

    cudaFree(host_version->blocks);

    cudaFree(host_version->chunk_ids);


    if (host_version->memory_control == device_only || host_version->memory_control == managed){
      cudaFree(host_version->memory);
    } else {
      cudaFreeHost(host_version->memory);
    }
    

    cudaFree(dev_version);

    cudaFreeHost(host_version);

  }

  // register a tree component
  __device__ inline void register_tree(uint64_t segment, uint16_t id) {
    if (segment >= num_segments) {

      #if GALLATIN_MEM_TABLE_DEBUG
      printf("Chunk issue: %llu > %llu\n", segment, num_segments);
      #endif

      #if BETA_TRAP_ON_ERR
      asm volatile ("trap;");
      #endif

    }

    chunk_ids[segment] = id;
  }

  // register a segment from the table.
  __device__ inline void register_size(uint64_t segment, uint16_t size) {
    if (segment >= num_segments) {

      #if GALLATIN_MEM_TABLE_DEBUG
      printf("Chunk issue\n");
      #endif

      #if BETA_TRAP_ON_ERR
      asm volatile ("trap;");
      #endif

    }

    size += 16;

    chunk_ids[segment] = size;
  }

  // get the void pointer to the start of a segment.
  __device__ inline char *get_segment_memory_start(uint64_t segment) {
    return memory + bytes_per_segment * segment;
  }

  // claim segment
  // to claim segment
  // set tree ID, set malloc_counter
  // free_counter is set
  // return;
  __device__ inline bool setup_segment(uint64_t segment, uint16_t tree_id) {
    uint64_t tree_alloc_size = get_tree_alloc_size(tree_id);

    // should stop interlopers
    bool did_set = set_tree_id(segment, tree_id);

    //this shouldn't fail.
    if (!did_set){

      #if GALLATIN_MEM_TABLE_DEBUG
      printf("Failed to set tree id for segment %lu\n", segment);
      #endif

      return false;
    }

    int num_blocks = get_blocks_per_segment(tree_id);

    //Segments now give out negative counters...
    //this allows us to A) specify # of blocks exactly on construction.
    // and B) still give out exact addresses when requesting (still 1 atomic.)
    //the trigger for a failed block alloc is going negative


    for (int i = 0; i < num_blocks; i++){
      queues[segment*blocks_per_segment+i] = nullptr;
    }

    __threadfence();

    if (calloc_mode){

      atomicExch(&calloc_counters[segment], 0);
      atomicExch(&calloc_enqueue_position[segment], 0);
      atomicExch(&calloc_enqueue_finished[segment], 0);

    }

    //modification, boot queue elements
    //as items can always interact with this, we simply reset.
    //init with blocks per segment so that mallocs always understand a true count
    atomicExch(&queue_counters[segment], 0);
    atomicExch(&queue_free_counters[segment], 0);
    atomicExch(&final_queue_free_counters[segment], 0);

    int old_active_count = atomicExch(&active_counts[segment], num_blocks-1);

    //init queue counters.


    #if GALLATIN_MEM_TABLE_DEBUG

    if (old_active_count != -1){
      printf("Old active count has live threads: %d\n", old_active_count);
    }


    // if (old_malloc < 0){
    //   printf("Did not fully reset segment %llu: %d malloc %d free\n", segment, old_malloc, old_free);

    // }
    #endif

    // if (old_malloc >= 0){
    //   #if BETA_TRAP_ON_ERR
    //     asm volatile ("trap;");
    //   #endif
    // }


    // gate to init is init_new_universe
    return true;
  }


  // set the tree id of a segment atomically
  //  returns true on success.
  __device__ inline bool set_tree_id(uint64_t segment, uint16_t tree_id) {
    return (atomicCAS((unsigned short int *)&chunk_ids[segment],
                      (unsigned short int)~0U,
                      (unsigned short int)tree_id) == (unsigned short int)~0U);
  }

  // atomically read tree id.
  // this may be faster with global load lcda instruction
  __device__ inline uint16_t read_tree_id(uint64_t segment) {

    #if GALLATIN_TABLE_GLOBAL_READ

      return gallatin::utils::global_read_uint16_t(&chunk_ids[segment]);

    #else

      return atomicCAS((unsigned short int *)&chunk_ids[segment],
                (unsigned short int)~0U, (unsigned short int)~0U);

    #endif

  }

  // return tree id to ~0
  __device__ inline bool reset_tree_id(uint64_t segment, uint16_t tree_id) {
    return (atomicCAS((unsigned short int *)&chunk_ids[segment],
                      (unsigned short int)tree_id,
                      (unsigned short int)~0U) == (unsigned short int)tree_id);
  }



  /******
  Set of helper functions to control queue entry and exit
  
  These allow threads to request slots from the queue and check if the queue is entirely full

  or entirely empty. 

  ******/

  //pull a slot from the segment
  //this acts as a gate over the malloc counters.
  __device__ inline int get_slot_in_segment(uint64_t segment){
    return atomicSub(&active_counts[segment], 1);
  }

  __device__ inline int return_slot_to_segment(uint64_t segment){
    return atomicAdd(&active_counts[segment], 1);
  }

  //helper to check if block is entirely free.
  //requires you to have a valid tree_id
  __device__ inline bool all_blocks_free(int active_count, uint64_t blocks_per_segment){

    return (active_count == blocks_per_segment-2);

  }

  //check if the count for a thread is valid
  //current condition is that negative numbers represent invalid requests.
  __device__ inline bool active_count_valid(int active_count){

    return (active_count >= 0);

  }


  __device__ inline uint increment_queue_position(uint64_t segment){

    return atomicAdd(&queue_counters[segment], 1);

  }

  __device__ inline uint increment_free_queue_position(uint64_t segment){

    return atomicAdd(&queue_free_counters[segment], 1);

  }

  //given that we have already written to an address,
  //atomicCAS loop to assert that write is finalized.
  //this is necessary
  __device__ inline void finalize_free_queue(uint64_t segment, uint position){

    while (atomicCAS(&final_queue_free_counters[segment], position, position+1) != position);

  }

  // request a segment from a block
  // this verifies that the segment is initialized correctly
  // and returns nullptr on failure.
  __device__ inline Block *get_block(uint64_t segment_id, uint16_t tree_id,
                              bool &empty) {


    empty = false;


    //precondition that if it's available we go for it...
    int active_count = get_slot_in_segment(segment_id);

    if (!active_count_valid(active_count)){

      return_slot_to_segment(segment_id);

      return nullptr;

    }

    //if global tree id's don't match, discard.
    uint16_t global_tree_id = read_tree_id(segment_id);

    // tree changed in interim - this can happen in correct behavior.
    // we correct by releasing back to the system, potentially rolling the segment back.
    if (global_tree_id != tree_id) {

      #if GALLATIN_MEM_TABLE_DEBUG

      printf("Segment %llu: Read old tree value: %u != %u\n", segment_id, tree_id, global_tree_id);

      #endif

      //slot can go back to a worthy thread
      //this saves the reset having to be pushed to the main manager.
      return_slot_to_segment(segment_id);

      __threadfence();

      return nullptr;
    }


    uint64_t blocks_in_segment = get_blocks_per_segment(tree_id);

    //if we have a valid spot, a queue position must exist
    int queue_pos = increment_queue_position(segment_id);

    Block * my_block;

    if (queue_pos < blocks_in_segment){

      my_block = get_block_from_global_block_id(segment_id*blocks_per_segment+queue_pos);

    } else {


      int queue_pos_wrapped = queue_pos % blocks_in_segment;

      //swap out the queue element for nullptr.
      my_block = (Block *) atomicExch((unsigned long long int *)&queues[segment_id*blocks_per_segment+queue_pos_wrapped], 0ULL);

    }

    if (my_block == nullptr){

      //printf("Bug\n");
      asm volatile ("trap;");

    }


    my_block->init_malloc(tree_id);

    if (active_count == 0) {
      empty = true;
    }

    return my_block;
    
    }

  //given a global block_id, return the block
  __device__ inline Block * get_block_from_global_block_id(uint64_t global_block_id){

  	return &blocks[global_block_id];

  }

  // snap a block back to its segment
  // needed for returning
  __device__ inline uint64_t get_segment_from_block_ptr(Block *block) {
    // this returns the stride in blocks
    uint64_t offset = (block - blocks);

    return offset / blocks_per_segment;
  }

  // get relative offset of a block in its segment.
  __device__ inline int get_relative_block_offset(Block *block) {
    uint64_t offset = (block - blocks);

    return offset % blocks_per_segment;
  }

  // given a pointer, find the associated block for returns
  // not yet implemented
  __device__ inline Block *get_block_from_ptr(void *ptr) {}

  // given a pointer, get the segment the pointer belongs to
  __device__ inline uint64_t get_segment_from_ptr(void *ptr) {
    uint64_t offset = ((char *)ptr) - memory;

    return offset / bytes_per_segment;
  }

  __device__ inline uint64_t get_segment_from_offset(uint64_t offset){

    return offset/get_max_allocations_per_segment();

  }

  // get the tree the segment currently belongs to
  __device__ inline int get_tree_from_segment(uint64_t segment) {
    return chunk_ids[segment];
  }

  // helper function for moving from power of two exponent to index
  static __host__ __device__ inline uint64_t get_p2_from_index(int index) {
    return (1ULL) << index;
  }

  // given tree id, return size of allocations.
  static __host__ __device__ inline uint64_t get_tree_alloc_size(uint16_t tree) {
    // scales up by smallest.
    return min_size * get_p2_from_index(tree);
  }

  // get relative position of block in list of all blocks
  __device__ inline uint64_t get_global_block_offset(Block *block) {
    return block - blocks;
  }

  // get max blocks per segment when formatted to a given tree size.
  static __host__ __device__ inline uint64_t get_blocks_per_segment(uint16_t tree) {
    uint64_t tree_alloc_size = get_tree_alloc_size(tree);

    return bytes_per_segment / (tree_alloc_size * 4096);
  }

  //get maximum # of allocations per segment
  //useful for converting alloc offsets into void *
  static __host__ __device__ inline uint64_t get_max_allocations_per_segment(){

  	//get size of smallest tree
  	return bytes_per_segment / min_size;

  }

  __device__ inline void * offset_to_allocation(uint64_t allocation, uint16_t tree_id){

  	uint64_t segment_id = allocation/get_max_allocations_per_segment();

  	uint64_t relative_offset = allocation % get_max_allocations_per_segment();

  	char * segment_mem_start = get_segment_memory_start(segment_id);


  	uint64_t alloc_size = get_tree_alloc_size(tree_id);

  	return (void *) (segment_mem_start + relative_offset*alloc_size);


  }


  //given a known tree id, snap an allocation back to the correct offset
  __device__ inline uint64_t allocation_to_offset(void * alloc, uint16_t tree_id){


      uint64_t byte_offset = (uint64_t) ((char *) alloc - memory);

      //segment id_should agree with upper function.
      uint64_t segment_id = byte_offset/bytes_per_segment;


      #if GALLATIN_MEM_TABLE_DEBUG

      uint64_t alt_segment = get_segment_from_ptr(alloc);

      if (segment_id != alt_segment){
        printf("Mismatch on segments in allocation to offset, %llu != %llu\n", segment_id, alt_segment);

        #if BETA_TRAP_ON_ERR
        asm volatile ("trap;");
        #endif
      }



      #endif





      char * segment_start = (char *) get_segment_memory_start(segment_id);

      uint64_t segment_byte_offset = (uint64_t) ((char *) alloc - segment_start);

      return segment_byte_offset/get_tree_alloc_size(tree_id) + segment_id*get_max_allocations_per_segment();



  }

  //enqueues a block into the calloc storage 
  __device__ inline bool calloc_free_block(Block * block_ptr, uint64_t & segment, uint16_t & global_tree_id, uint64_t & num_blocks){


    uint current_enqueue_position = atomicAdd(&calloc_enqueue_position[segment],1);

    uint live_enqueue_position = current_enqueue_position % num_blocks;

    uint64_t old_block = atomicExch((unsigned long long int *)&calloc_queues[segment*blocks_per_segment+live_enqueue_position], (unsigned long long int) block_ptr);


    while (atomicCAS(&calloc_enqueue_finished[segment], current_enqueue_position, current_enqueue_position+1) != current_enqueue_position);
    
    //TODO - make this actually calculate fill.
    
    int return_id = atomicAdd(&calloc_counters[segment], 1);

    if (return_id == 0){
      return true;
    }

    return false;

  }


  //return which index in the queue structure is valid
  //and start swap
  //this does not increment find index yet.
  __device__ inline uint reserve_segment_slot(Block * block_ptr, uint64_t & segment, uint16_t & global_tree_id, uint64_t & num_blocks){


    //system allows for multiple people to reserve simultaneously...
    //claum 0 - malloc 0, reclaim 0.


    //new idea - 4 atomics :[
    //get unique index via atomicAdd
    //atomic Exch to set
    //get unique setter via
    //then atomicCAS loop on finale
    //then unset index


    uint current_enqueue_position = increment_free_queue_position(segment);

    uint live_enqueue_position = current_enqueue_position % num_blocks;

    uint64_t old_block = atomicExch((unsigned long long int *)&queues[segment*blocks_per_segment+live_enqueue_position], (unsigned long long int) block_ptr);

    finalize_free_queue(segment, current_enqueue_position);

    //TODO - make this actually calculate fill.
    return live_enqueue_position;

    // uint current_enqueue_position = read_free_queue_position(segment);


    // while (true){

    //   uint live_enqueue_position = current_enqueue_position % num_blocks;

    //   uint64_t old_block = atomicCAS((unsigned long long int *)&queues[segment*blocks_per_segment+live_enqueue_position], 0ULL, (unsigned long long int) block_ptr);

    //   if (old_block == 0ULL){
    //     //success! swapped in successfully
    //     //signal to other threads that swap is possible.

    //     increment_free_queue_position(segment);

    //     __threadfence();
    //     return current_enqueue_position;

    //   }

    //   //drat, we failed!
    //   //we know that slot is occupied, so lets try the next one!
    //   current_enqueue_position++;


    // }
    
    //get enqueue position.
    // uint enqueue_position = increment_free_queue_position(segment) % num_blocks;

    // //swap into queue
    // atomicExch((unsigned long long int *)&queues[segment*blocks_per_segment+enqueue_position], (unsigned long long int) block_ptr);


    // __threadfence();

    // return enqueue_position;

  }


  //once the messy logic of the tree reset is done, clean up
  __device__ inline bool finish_freeing_block(uint64_t segment, uint64_t num_blocks){

    int return_id = return_slot_to_segment(segment);

    if (all_blocks_free(return_id, num_blocks)){

      if (atomicCAS(&active_counts[segment], num_blocks-1, -1) == num_blocks-1){

        //exclusive owner
        return true;
      }
    }

    return false;

  }

  __device__ inline uint read_free_queue_position(uint64_t segment){
    return gallatin::utils::ldca(&queue_free_counters[segment]);
  }

  __device__ inline uint64_t get_bytes_per_segment(){
    return bytes_per_segment;
  }


  __host__ inline uint64_t report_free(){

    uint64_t * counter;

    cudaMallocManaged((void **)&counter, sizeof(uint64_t));

    cudaDeviceSynchronize();

    counter[0] = 0;

    cudaDeviceSynchronize();


    //this will probs break

    uint64_t local_num_segments;

    cudaMemcpy(&local_num_segments, &this->num_segments, sizeof(uint64_t), cudaMemcpyDeviceToHost);

    uint64_t local_blocks_per_segment;

    cudaMemcpy(&local_blocks_per_segment, &this->blocks_per_segment, sizeof(uint64_t), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    uint64_t total_num_blocks = local_blocks_per_segment*local_num_segments;

    count_block_free_kernel<my_type><<<(total_num_blocks-1)/256+1,256>>>(this, total_num_blocks, counter);

    cudaDeviceSynchronize();

    uint64_t return_val = counter[0];

    cudaFree(counter);

    return return_val;

  }

  __host__ inline uint64_t report_live(){

    uint64_t * counter;

    cudaMallocManaged((void **)&counter, sizeof(uint64_t));

    cudaDeviceSynchronize();

    counter[0] = 0;

    cudaDeviceSynchronize();


    //this will probs break

    uint64_t local_num_segments;

    cudaMemcpy(&local_num_segments, &this->num_segments, sizeof(uint64_t), cudaMemcpyDeviceToHost);

    uint64_t local_blocks_per_segment;

    cudaMemcpy(&local_blocks_per_segment, &this->blocks_per_segment, sizeof(uint64_t), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    uint64_t total_num_blocks = local_blocks_per_segment*local_num_segments;

    count_block_live_kernel<my_type><<<(total_num_blocks-1)/256+1,256>>>(this, total_num_blocks, counter);

    cudaDeviceSynchronize();

    uint64_t return_val = counter[0];

    cudaFree(counter);

    return return_val;

  }


  __device__ inline uint64_t calculate_overhead(){

    //overhead per segment
    //4 bytes active count
    //4 bytes queue_inc
    //4 bytes_queue_dec
    //2 bytes tree_id
    //+ blocks_per_segment*sizeof(block) 
    //+ blocks+per_segment*sizeof(block *)  - this is the queue structure.


    return sizeof(my_type) + num_segments*(14 + blocks_per_segment*(sizeof(Block)+sizeof(Block *)));

  }

  __device__ inline bool owns_allocation(void * alloc){


    uint64_t byte_difference = ( (char *) alloc - (char *) memory);

    return (byte_difference < num_segments*bytes_per_segment);

  }


};

}  // namespace allocators

}  // namespace gallatin

#endif  // End of VEB guard