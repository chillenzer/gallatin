#ifndef GALLATIN_VEB_TREE
#define GALLATIN_VEB_TREE
// A CUDA implementation of the Van Emde Boas tree, made by Hunter McCoy
// (hunter@cs.utah.edu)

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without l> imitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so,
// subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial
// portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
// IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// inlcudes
#include <cuda.h>
#include <cuda_runtime_api.h>

#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <gallatin/allocators/alloc_utils.cuh>
#include <gallatin/allocators/murmurhash.cuh>

// thank you interwebs https://leimao.github.io/blog/Proper-CUDA-Error-Checking/
#define CHECK_CUDA_ERROR(val) check((val), #val, __FILE__, __LINE__)
template <typename T>
void check(T err, const char *const func, const char *const file,
           const int line) {
  if (err != cudaSuccess) {
    std::cerr << "CUDA Runtime Error at: " << line << ":" << std::endl
              << file << std::endl;
    std::cerr << cudaGetErrorString(err) << " " << func << std::endl;
    // We don't exit when we encounter CUDA errors in this example.
    std::exit(EXIT_FAILURE);
  }
}

#ifndef VEB_DEBUG_PRINTS
#define VEB_DEBUG_PRINTS 0
#endif

#define VEB_RESTART_CUTOFF 30

#define VEB_GLOBAL_LOAD 1
#define VEB_MAX_ATTEMPTS 15

namespace gallatin {

namespace allocators {

// define macros
#define MAX_VALUE(nbits) ((1ULL << (nbits)) - 1)
#define BITMASK(nbits) ((nbits) == 64 ? 0xffffffffffffffff : MAX_VALUE(nbits))

#define SET_BIT_MASK(index) ((1ULL << index))

// cudaMemset is being weird
__global__ inline void init_bits(uint64_t *bits, uint64_t items_in_universe) {
  uint64_t tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid >= items_in_universe) return;

  uint64_t high = tid / 64;

  uint64_t low = tid % 64;

  atomicOr((unsigned long long int *)&bits[high], SET_BIT_MASK(low));

  // bits[tid] = ~(0ULL);
}

template <typename veb_tree_kernel_type>
__global__ inline void veb_report_fill_kernel(veb_tree_kernel_type *tree,
                                       uint64_t num_threads,
                                       uint64_t *fill_count) {
  uint64_t tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid >= num_threads) return;

  uint64_t my_fill = __popcll(tree->layers[tree->num_layers - 1]->bits[tid]);

  atomicAdd((unsigned long long int *)fill_count,
            (unsigned long long int)my_fill);
}

// a layer is a bitvector used for ops
// internally, they are just uint64_t's as those are the fastest to work with

// The graders might be asking, "why the hell did you not include max and min?"
// with the power of builtin __ll commands (mostly __ffsll) we can recalculate
// those in constant time on the blocks
//  which *should* be faster than a random memory load, as even the prefetch is
//  going to be at least one cycle to launch this saves ~66% memory with no
//  overheads!
struct layer {
  // make these const later
  uint64_t universe_size;
  uint64_t num_blocks;
  uint64_t *bits;
  // int * max;
  // int * min;

  __host__ inline static layer *generate_on_device(uint64_t items_in_universe) {
    uint64_t ext_num_blocks = (items_in_universe - 1) / 64 + 1;

    // printf("Universe of %lu items in %lu bytes\n", items_in_universe,
    // ext_num_blocks);

    layer *host_layer;

    cudaMallocHost((void **)&host_layer, sizeof(layer));

    uint64_t *dev_bits;

    cudaMalloc((void **)&dev_bits, sizeof(uint64_t) * ext_num_blocks);

    cudaMemset(dev_bits, 0, sizeof(uint64_t) * ext_num_blocks);

    init_bits<<<(items_in_universe - 1) / 256 + 1, 256>>>(dev_bits,
                                                          items_in_universe);

    cudaDeviceSynchronize();

    host_layer->universe_size = items_in_universe;

    host_layer->num_blocks = ext_num_blocks;

    host_layer->bits = dev_bits;

    layer *dev_layer;

    cudaMalloc((void **)&dev_layer, sizeof(layer));

    cudaMemcpy(dev_layer, host_layer, sizeof(layer), cudaMemcpyHostToDevice);

    cudaDeviceSynchronize();

    cudaFreeHost(host_layer);

    cudaDeviceSynchronize();

    return dev_layer;
  }

  //special init function for Gallatin
  //tree is not guaranteed to be initialized until a synchronize is called
  //This function allows for multiple layers to be initialized simultaneously.
  __host__ inline static layer *generate_on_device_nowait(uint64_t items_in_universe) {
    uint64_t ext_num_blocks = (items_in_universe - 1) / 64 + 1;

    // printf("Universe of %lu items in %lu bytes\n", items_in_universe,
    // ext_num_blocks);

    layer *host_layer;

    cudaMallocHost((void **)&host_layer, sizeof(layer));

    uint64_t *dev_bits;

    cudaMalloc((void **)&dev_bits, sizeof(uint64_t) * ext_num_blocks);

    cudaMemset(dev_bits, 0, sizeof(uint64_t) * ext_num_blocks);

    init_bits<<<(items_in_universe - 1) / 256 + 1, 256>>>(dev_bits,
                                                          items_in_universe);

    //cudaDeviceSynchronize();

    host_layer->universe_size = items_in_universe;

    host_layer->num_blocks = ext_num_blocks;

    host_layer->bits = dev_bits;

    layer *dev_layer;

    cudaMalloc((void **)&dev_layer, sizeof(layer));

    cudaMemcpy(dev_layer, host_layer, sizeof(layer), cudaMemcpyHostToDevice);

    //cudaDeviceSynchronize();

    cudaFreeHost(host_layer);

    //cudaDeviceSynchronize();

    return dev_layer;
  }


  __device__ inline static uint64_t get_num_blocks(uint64_t items_in_universe) {
    return (items_in_universe - 1) / 64 + 1;
  }

  __device__ inline static uint64_t get_size_bytes(uint items_in_universe) {
    return get_num_blocks(items_in_universe) * sizeof(uint64_t);
  }

  // given a device layer initialize.
  __device__ inline void init_from_array(uint64_t items_in_universe, uint64_t *array) {
    universe_size = items_in_universe;

    num_blocks = get_num_blocks(items_in_universe);

    for (uint64_t i = 0; i < num_blocks; i++) {
      bits[i] = ~0ULL;
    }

    __threadfence();

    return;
  }

  __host__ inline static void free_on_device(layer *dev_layer) {
    layer *host_layer;

    cudaMallocHost((void **)&host_layer, sizeof(layer));

    cudaMemcpy(host_layer, dev_layer, sizeof(layer), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    cudaFree(host_layer->bits);

    cudaFreeHost(host_layer);
  }

  __device__ inline uint64_t insert(uint64_t high, int low) {
    return atomicOr((unsigned long long int *)&bits[high], SET_BIT_MASK(low));
  }

  __device__ inline uint64_t remove(uint64_t high, int low) {
    return atomicAnd((unsigned long long int *)&bits[high], ~SET_BIT_MASK(low));
  }

  __device__ inline int find_next(uint64_t high, int low) {
    // printf("High is %lu, num blocks is %lu\n", high, num_blocks);
    if (bits == nullptr) {

      #if VEB_DEBUG_PRINTS
      printf("Nullptr\n");
      #endif
    }

    if (high >= universe_size) {
      #if VEB_DEBUG_PRINTS
      printf("High issue %lu > %lu\n", high, universe_size);
      #endif
      return -1;
    }

#if VEB_GLOBAL_LOAD
    gallatin::utils::ldca(&bits[high]);
#endif

    if (low == -1) {
      return __ffsll(bits[high]) - 1;
    }

    return __ffsll(bits[high] & ~BITMASK(low + 1)) - 1;
  }

  //__device__ inline int

  // returns true if item in bitmask.
  __device__ inline bool query(uint64_t high, int low) {
#if VEB_GLOBAL_LOAD
    gallatin::utils::ldca(&bits[high]);
#endif

    return (bits[high] & SET_BIT_MASK(low));
  }

  __device__ inline void set_new_universe(uint64_t items_in_universe) {
    universe_size = items_in_universe;
    num_blocks = get_num_blocks(items_in_universe);

    for (uint64_t i = 0; i < num_blocks - 1; i++) {
      atomicOr((unsigned long long int *)&bits[i], ~0ULL);
    }

    // uint64_t high = items_in_universe / 64;
    uint64_t low = items_in_universe % 64;

    atomicOr((unsigned long long int *)&bits[num_blocks - 1], BITMASK(low));

    return;
  }

  //if a failure occurs, rollback previously acquired segments!
  __device__ inline void rollback(uint64_t start_block, uint64_t bits_to_set){

    while (bits_to_set > 64){

      atomicOr((unsigned long long int *)&bits[start_block], BITMASK(64));

      bits_to_set-=64;

      start_block++;

    }

    atomicOr((unsigned long long int *)&bits[start_block], BITMASK(bits_to_set));

    return;

  }

  __device__ inline uint64_t gather_multiple(uint64_t num_contiguous){

    uint64_t start_block = num_blocks-1;

    //find a valid start

    uint64_t num_needed = num_contiguous;

    while (start_block != 0){

      //reset counter as we may have failed a previous iteration.
      num_contiguous = num_needed;

      //ldca loads bits, ~ inverts, so __ffsll(~block) is first index that is 0 - first contiguous section to the right.
      //since this is length need to subtract from 64
      int contig_start = gallatin::utils::__cfcll(gallatin::utils::ldca(&bits[start_block]));

      if (contig_start == 0){
        start_block -=1;
        continue;
      }

      if (contig_start >= num_contiguous){

        //special case - attempt to solve
        auto acq_bitmask = BITMASK(num_contiguous) << (contig_start-num_contiguous);

        auto acquired_bits = atomicAnd((unsigned long long int *)&bits[start_block], ~acq_bitmask);

        //if acquired bits match exactly.
        if (__popcll(acquired_bits & acq_bitmask) == num_contiguous){

          //return set bits.
          return start_block*64+(contig_start-num_contiguous);

        } else {

          //rollback - only rollback bits that were set.
          atomicOr((unsigned long long int *)&bits[start_block], (acq_bitmask & acquired_bits));

          //try again - since things changed, maybe valid this time - if not, will automatically progress
          continue;

        }

      }

      //phases - determine how many blocks available at the start - if more than we need, just attempt?

      auto acquired_bits = atomicAnd((unsigned long long int *)&bits[start_block], ~BITMASK(contig_start));

      bool succeeded = true;

      if (__popcll(acquired_bits & BITMASK(contig_start)) == contig_start){

        //valid to start traversal

        num_contiguous -= contig_start;

        while (num_contiguous > 64){

          start_block--;

          acquired_bits = atomicAnd((unsigned long long int *)&bits[start_block], 0ULL);

          if (__popcll(acquired_bits) != 64){

            //undo and rollback
            atomicOr((unsigned long long int *)&bits[start_block], (unsigned long long int) acquired_bits);

            rollback(start_block+1, (num_needed - num_contiguous));


            succeeded = false;

            //continue search from new start: up to this point nothing large enough is valid.
            break;

          }

          num_contiguous -=64;

        }

        //on failure retry
        if (!succeeded) continue;

        start_block--;

        
        //otherwise we need to acquire the last segment.
        //generate last mask and shift up
        auto final_bitmask = BITMASK(num_contiguous) << (64-num_contiguous);

        auto final_bits = atomicAnd((unsigned long long int *)&bits[start_block], ~final_bitmask);

        if (__popcll(final_bits & final_bitmask) == num_contiguous){
          return start_block*64+64-num_contiguous;
        } else {

          //full reset
          atomicOr((unsigned long long int *)&bits[start_block], final_bitmask & final_bits);

          rollback(start_block+1, (num_needed-num_contiguous));

          continue;

        }


      } else {

        //undo and retry
        //same as before, updated info allows for fast retry.
        atomicOr((unsigned long long int *)&bits[start_block], acquired_bits & BITMASK(contig_start));

        continue;


      }


    }

    rollback(0, (num_needed-num_contiguous));

    return ~0ULL;


  }


  //forcefully clean up indices
  //only occurs when lower layers fully allocated with gather_multiple.
  __device__ inline void remove_contiguous(uint64_t start_index, uint64_t num_indices){


    uint64_t block_index = start_index/64;

    int block_start = start_index % 64;


    while (num_indices + block_start > 64){


      int num_removed = 64 - block_start;


      auto bitmask = BITMASK(num_removed) << block_start;

      atomicAnd((unsigned long long int *)&bits[block_index], ~bitmask);

      block_start = 0;

      block_index += 1; 

      num_indices -= num_removed;

    }

    //finally, unset scragglers.
    auto bitmask = BITMASK(num_indices) << block_start;

    atomicAnd((unsigned long long int *)&bits[block_index], ~bitmask);

    return;


  }

  //add back multiple bits in a contiguous band
  //accounts for starting and ending in the middle of a segment!
  __device__ inline void return_multiple(uint64_t start_index, uint64_t num_indices){


    uint64_t block_index = start_index/64;

    int block_start = start_index % 64;

    while (num_indices + block_start > 64){

      int num_added = 64 - block_start;

      auto bitmask = BITMASK(num_added) << block_start;

      atomicOr((unsigned long long int *)&bits[block_index], bitmask);

      block_start = 0;

      block_index +=1;

      num_indices -= num_added;

    }

    auto bitmask = BITMASK(num_indices) << block_start;

    atomicOr((unsigned long long int *)&bits[block_index], bitmask);


  }


};

struct veb_tree {
  uint64_t seed;
  uint64_t total_universe;
  int num_layers;

  int original_num_layers;
  layer **layers;


  // don't think this calculation is correct
  __host__ inline static veb_tree *generate_on_device(uint64_t universe,
                                               uint64_t ext_seed) {
    veb_tree *host_tree;

    cudaMallocHost((void **)&host_tree, sizeof(veb_tree));

    int max_height = 64 - __builtin_clzll(universe);

    assert(max_height >= 1);
    // round up but always assume
    int ext_num_layers = (max_height - 1) / 6 + 1;

    layer **host_layers;

    cudaMallocHost((void **)&host_layers, ext_num_layers * sizeof(layer *));

    uint64_t ext_universe_size = universe;

    for (int i = 0; i < ext_num_layers; i++) {
      host_layers[ext_num_layers - 1 - i] =
          layer::generate_on_device(ext_universe_size);

      ext_universe_size = (ext_universe_size - 1) / 64 + 1;
    }

    layer **dev_layers;

    cudaMalloc((void **)&dev_layers, ext_num_layers * sizeof(layer *));

    cudaMemcpy(dev_layers, host_layers, ext_num_layers * sizeof(layer *),
               cudaMemcpyHostToDevice);

    cudaDeviceSynchronize();

    cudaFreeHost(host_layers);

    // setup host structure
    host_tree->num_layers = ext_num_layers;
    host_tree->original_num_layers = ext_num_layers;

    host_tree->layers = dev_layers;

    host_tree->seed = ext_seed;

    host_tree->total_universe = universe;

    veb_tree *dev_tree;
    cudaMalloc((void **)&dev_tree, sizeof(veb_tree));

    cudaMemcpy(dev_tree, host_tree, sizeof(veb_tree), cudaMemcpyHostToDevice);

    cudaFreeHost(host_tree);

    return dev_tree;
  }


  __host__ inline static veb_tree *generate_on_device_nowait(uint64_t universe,
                                               uint64_t ext_seed) {
    veb_tree *host_tree;

    cudaMallocHost((void **)&host_tree, sizeof(veb_tree));

    int max_height = 64 - __builtin_clzll(universe);

    assert(max_height >= 1);
    // round up but always assume
    int ext_num_layers = (max_height - 1) / 6 + 1;

    layer **host_layers;

    cudaMallocHost((void **)&host_layers, ext_num_layers * sizeof(layer *));

    uint64_t ext_universe_size = universe;

    for (int i = 0; i < ext_num_layers; i++) {
      host_layers[ext_num_layers - 1 - i] =
          layer::generate_on_device_nowait(ext_universe_size);

      ext_universe_size = (ext_universe_size - 1) / 64 + 1;
    }

    layer **dev_layers;

    cudaMalloc((void **)&dev_layers, ext_num_layers * sizeof(layer *));

    cudaMemcpy(dev_layers, host_layers, ext_num_layers * sizeof(layer *),
               cudaMemcpyHostToDevice);

    //cudaDeviceSynchronize();

    cudaFreeHost(host_layers);

    // setup host structure
    host_tree->num_layers = ext_num_layers;
    host_tree->original_num_layers = ext_num_layers;

    host_tree->layers = dev_layers;

    host_tree->seed = ext_seed;

    host_tree->total_universe = universe;

    veb_tree *dev_tree;
    cudaMalloc((void **)&dev_tree, sizeof(veb_tree));

    cudaMemcpy(dev_tree, host_tree, sizeof(veb_tree), cudaMemcpyHostToDevice);

    cudaFreeHost(host_tree);

    return dev_tree;
  }

  // if all pointers point to nullptr
  // how big are we?
  // This is the number of bytes required for both the main object
  // and all layer pointers.
  //  static __host__ inline uint64_t get_size_bytes_noarray(){

  // 	uint64_t bytes = sizof(my_type)

  // }

  // always free from the layers we started with.
  __host__ inline static void free_on_device(veb_tree *dev_tree) {
    veb_tree *host_tree;

    cudaMallocHost((void **)&host_tree, sizeof(veb_tree));

    cudaMemcpy(host_tree, dev_tree, sizeof(veb_tree), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    int ext_num_layers = host_tree->original_num_layers;

    // printf("Cleaning up tree with %d layers\n", ext_num_layers);

    layer **host_layers;

    cudaMallocHost((void **)&host_layers, ext_num_layers * sizeof(layer *));

    cudaMemcpy(host_layers, host_tree->layers, ext_num_layers * sizeof(layer *),
               cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    for (int i = 0; i < ext_num_layers; i++) {
      layer::free_on_device(host_layers[i]);
    }

    cudaDeviceSynchronize();

    cudaFreeHost(host_layers);

    cudaFreeHost(host_tree);

    cudaFree(dev_tree);
  }

  __device__ inline bool float_up(int &layer, uint64_t &high, int &low) {
    layer -= 1;

    low = high & BITMASK(6);
    high = high >> 6;

    return (layer >= 0);
  }

  __device__ inline bool float_down(int &layer, uint64_t &high, int &low) {
    layer += 1;
    high = (high << 6) + low;
    low = -1;

    return (layer < num_layers);
  }

  __device__ inline void init_new_universe(uint64_t items_in_universe) {
    uint64_t ext_universe_size = items_in_universe;

    int max_height = 64 - __builtin_clzll(items_in_universe);

    assert(max_height >= 1);
    // round up but always assume
    int ext_num_layers = (max_height - 1) / 6 + 1;

    num_layers = ext_num_layers;

    total_universe = items_in_universe;

    __threadfence();

    for (int i = 0; i < ext_num_layers; i++) {
      layers[ext_num_layers - 1 - i]->set_new_universe(ext_universe_size);

      ext_universe_size = (ext_universe_size - 1) / 64 + 1;
    }
  }

  // base setup - only works with lowest level
  __device__ inline bool remove(uint64_t delete_val) {
    uint64_t high = delete_val >> 6;

    int low = delete_val & BITMASK(6);

    int layer = num_layers - 1;

    uint64_t old = layers[layer]->remove(high, low);

    if (!(old & SET_BIT_MASK(low))) return false;

    while (__popcll(old) == 1 && float_up(layer, high, low)) {
      old = layers[layer]->remove(high, low);
    }

    return true;

    // assert (high == delete_val/64);
  }

  __device__ inline bool insert(uint64_t insert_val) {
    uint64_t high = insert_val >> 6;

    int low = insert_val & BITMASK(6);

    int layer = num_layers - 1;

    uint64_t old = layers[layer]->insert(high, low);

    if ((old & SET_BIT_MASK(low))) return false;

    while (__popcll(old) == VEB_RESTART_CUTOFF && float_up(layer, high, low)) {
      old = layers[layer]->insert(high, low);
    }

    return true;
  }

  __device__ inline bool insert_force_update(uint64_t insert_val) {
    uint64_t high = insert_val >> 6;

    int low = insert_val & BITMASK(6);

    int layer = num_layers - 1;

    uint64_t old = layers[layer]->insert(high, low);

    if ((old & SET_BIT_MASK(low))){

      #if VEB_DEBUG_PRINTS
      printf("Bit %d already set...\n", low);
      #endif

      return false;
    } 

    while (__popcll(old) == 0 && float_up(layer, high, low)) {
      old = layers[layer]->insert(high, low);
    }

    return true;
  }

  // insert, but we're not running probabilistically.
  // inserting into a block *must* force it to make changes visible at the
  // highest level
  //  __device__ inline bool insert_force_update(uint64_t insert_val){

  // 	uint64_t high = insert_val >> 6;

  // 	int low = insert_val & BITMASK(6);

  // 	int layer = num_layers - 1;

  // 	uint64_t old = layers[layer]->insert(high, low);

  // 	if ((old & SET_BIT_MASK(low))) return false;

  // 	while (float_up(layer, high, low)){
  // 		old = layers[layer]->insert(high, low);
  // 	}

  // 	return true;

  // }

  // non atomic
  __device__ inline bool query(uint64_t query_val) {
    uint64_t high = query_val >> 6;
    int low = query_val & BITMASK(6);

    return layers[num_layers - 1]->query(high, low);
  }

  __device__ __host__ inline static uint64_t fail() { return ~0ULL; }

  // finds the next one
  // this does one float up/ float down attempt
  // which gathers ~80% of items from testing.
  __device__ inline uint64_t successor(uint64_t query_val) {
    // debugging
    // this doesn't trigger so not the cause.

    uint64_t high = query_val >> 6;
    int low = query_val & BITMASK(6);

    int layer = num_layers - 1;

    while (true) {
      int found_idx = layers[layer]->find_next(high, low);

      if (found_idx == -1) {
        if (layer == 0) return veb_tree::fail();

        float_up(layer, high, low);
        continue;

      } else {
        break;
      }
    }

    while (layer != (num_layers - 1)) {
      low = layers[layer]->find_next(high, low);

      if (low == -1) {
        return veb_tree::fail();
      }
      float_down(layer, high, low);
    }

    low = layers[layer]->find_next(high, low);

    if (low == -1) return veb_tree::fail();

    return (high << 6) + low;
  }

  // allow for multiple loops
  // this is obviously slower / more divergent, but can help on small trees
  // guarantee that all items can be retreived is probabilistic
  __device__ inline uint64_t successor_thorough(uint64_t query_val) {
    uint64_t high = query_val >> 6;
    int low = query_val & BITMASK(6);

    int layer = num_layers - 1;

    while (true) {
      // float up as little as possible

      while (true) {
        int found_idx = layers[layer]->find_next(high, low);

        if (found_idx == -1) {
          if (layer == 0) return veb_tree::fail();

          float_up(layer, high, low);
          continue;

        } else {
          break;
        }
      }

      while (layer != (num_layers - 1)) {
        low = layers[layer]->find_next(high, low);

        if (low == -1) {
          break;
        }
        float_down(layer, high, low);
      }

      low = layers[layer]->find_next(high, low);

      if (low != -1) {
        return (high << 6) + low;
      }
    }
  }

  __device__ inline uint64_t lock_offset(uint64_t start) {
    // temporarily clipped for debugging
    if (query(start) && remove(start)) {
      return start;
    }

    // return veb_tree::fail();

    while (true) {
      // start = successor(start);
      start = successor_thorough(start);

      if (start == veb_tree::fail()) return start;

      // this successor search is returning massive values - why?
      if (remove(start)) {
        return start;
      }
    }
  }

  // find the first index
  __device__ inline uint64_t find_first_valid_index() {
    if (query(0)) return 0;

    return successor_thorough(0);
  }

  __device__ inline uint64_t find_random_valid_index(){

    uint64_t tid = threadIdx.x + blockIdx.x * blockDim.x;

    uint64_t hash1 =
        gallatin::hashers::MurmurHash64A(&tid, sizeof(uint64_t), seed);

    tid = threadIdx.x + blockIdx.x * blockDim.x;

    uint64_t hash2 =
        gallatin::hashers::MurmurHash64A(&tid, sizeof(uint64_t), hash1);

    int attempts = 0;

    while (attempts < VEB_MAX_ATTEMPTS) {
      // uint64_t index_to_start = (hash1+attempts*hash2) % (total_universe-64);
      uint64_t index_to_start = (hash1 + attempts * hash2) % (total_universe);

      if (query(index_to_start)) return index_to_start;

      uint64_t index = successor_thorough(index_to_start);

      if (index != ~0ULL) return index;


      attempts+=1;

    }

    return successor_thorough(0);

  }

  __device__ inline uint64_t malloc_first() {
    int attempts = 0;

    while (attempts < VEB_MAX_ATTEMPTS) {
      uint64_t offset = lock_offset(0);

      if (offset != veb_tree::fail()) return offset;

      attempts += 1;
    }

    return veb_tree::fail();
  }

  __device__ inline uint64_t malloc() {
    // make several attempts at malloc?

    uint64_t tid = threadIdx.x + blockIdx.x * blockDim.x;

    uint64_t hash1 =
        gallatin::hashers::MurmurHash64A(&tid, sizeof(uint64_t), seed);

    tid = threadIdx.x + blockIdx.x * blockDim.x;

    uint64_t hash2 =
        gallatin::hashers::MurmurHash64A(&tid, sizeof(uint64_t), hash1);

    int attempts = 0;

    while (attempts < VEB_MAX_ATTEMPTS) {
      // uint64_t index_to_start = (hash1+attempts*hash2) % (total_universe-64);
      uint64_t index_to_start = (hash1 + attempts * hash2) % (total_universe);

      if (index_to_start == ~0ULL) {
        index_to_start = 0;

        #if VEB_DEBUG_PRINTS
        printf("U issue\n");
        #endif
      }

      #if VEB_DEBUG_PRINTS
      if (index_to_start >= total_universe) printf("Huge index error\n");
      #endif

      uint64_t offset = lock_offset(index_to_start);

      if (offset != veb_tree::fail()) return offset;

      attempts++;
    }

    return lock_offset(0);
  }

  __device__ inline uint64_t get_largest_allocation() { return total_universe; }

  __host__ inline uint64_t host_get_universe() {
    veb_tree *host_version;

    cudaMallocHost((void **)&host_version, sizeof(veb_tree));

    cudaMemcpy(host_version, this, sizeof(veb_tree), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    uint64_t ret_value = host_version->total_universe;

    cudaFreeHost(host_version);

    return ret_value;
  }

  __host__ inline uint64_t report_fill() {
    uint64_t *fill_count;

    cudaMallocManaged((void **)&fill_count, sizeof(uint64_t));

    cudaDeviceSynchronize();

    fill_count[0] = 0;

    cudaDeviceSynchronize();

    uint64_t max_value = report_max();

    uint64_t num_threads = (max_value - 1) / 64 + 1;

    veb_report_fill_kernel<veb_tree>
        <<<(num_threads - 1) / 512 + 1, 512>>>(this, num_threads, fill_count);

    cudaDeviceSynchronize();

    uint64_t return_val = fill_count[0];

    cudaFree(fill_count);

    return return_val;
  }

  __host__ inline uint64_t report_max() {
    // return 1;
    return host_get_universe();
  }


  __device__ inline uint64_t calculate_overhead(){

    uint64_t overhead = sizeof(veb_tree);

    for (int i =0; i < num_layers; i++){

      overhead += sizeof(layer) + layers[i]->num_blocks*8;

    }

    return overhead;

  }


  __device__ inline uint64_t maybe_remove_layer_bits(int layer, uint64_t start_bit, uint64_t bits_to_check){


    uint64_t working_bit = start_bit;

    while (working_bit < start_bit+bits_to_check){




      uint64_t bits = gallatin::utils::ldca(&layers[layer+1]->bits[working_bit]);

      if (bits == 0){

        uint64_t high = working_bit / 64;

        int low = working_bit % 64;

        layers[layer]->remove(high, low);

      }

      working_bit++;

    }

  }

  __device__ inline uint64_t maybe_return_layer_bits(int layer, uint64_t start_bit, uint64_t bits_to_check){


    uint64_t working_bit = start_bit;

    while (working_bit < start_bit+bits_to_check){




      uint64_t bits = gallatin::utils::ldca(&layers[layer+1]->bits[working_bit]);

      if (__popcll(bits) == 64){

        uint64_t high = working_bit / 64;

        int low = working_bit % 64;

        layers[layer]->insert(high, low);

      }

      working_bit++;

    }

  }

  //grab multiple segments, starting from the back
  //this algorithm works by generating masks and attempting to apply them
  //for each segment - determine if there is a valid section at the start using ffs
  //then work backwords!
  __device__ inline uint64_t gather_multiple(uint64_t num_contiguous){


    //starting from the back, find a section containing

    uint64_t found = layers[num_layers-1]->gather_multiple(num_contiguous);

    uint64_t original_found = found;

    if (found != fail()){

      //working from the bottom up
      for (int i = num_layers-2; i >=0; i--){

        //should round up - need to check all.
        auto tread_high = (found + num_contiguous -1)/64 + 1;

        auto tread_low = found/64;

        found = tread_low;

        num_contiguous = tread_high-tread_low;

        maybe_remove_layer_bits(i, found, num_contiguous);

      }

      return original_found;


    }


    //if we make it to the end, fail out - no contiguous alloc available.
    return fail();

  }

  __device__ inline void return_multiple(uint64_t start_bit, uint64_t num_contiguous){

    layers[num_layers-1]->return_multiple(start_bit, num_contiguous);


    for (int i = num_layers-2; i>=0; i--){

        //should round up - need to check all.
        auto tread_high = (start_bit + num_contiguous -1)/64 + 1;

        auto tread_low = start_bit/64;

        start_bit = tread_low;

        num_contiguous = tread_high-tread_low;

        maybe_return_layer_bits(i, start_bit, num_contiguous);

    }

  }

  // //teams work togther to find new allocations
  // __device__ inline uint64_t team_malloc(){

  // 	cg::coalesced_group active_threads = cg::coalesced_threads();

  // 	int allocation_index_bit = 0;

  // }
};

}  // namespace allocators

}  // namespace gallatin

#endif  // End of VEB guard