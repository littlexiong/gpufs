/*
* This expermental software is provided AS IS.
* Feel free to use/modify/distribute,
* If used, please retain this disclaimer and cite
* "GPUfs: Integrating a file system with GPUs",
* M Silberstein,B Ford,I Keidar,E Witchel
* ASPLOS13, March 2013, Houston,USA
*/

#include "fs_constants.h"
#include "util.cu.h"
#include "fs_calls.cu.h"
#include <sys/mman.h>
#include <stdio.h>
#include "gloop.h"


__device__ volatile INIT_LOCK init_lock;
__device__ volatile LAST_SEMAPHORE last_lock;


__forceinline__ __device__ void memcpy_thread(volatile char* dst, const volatile char* src, uint size)
{
        for( int i=0;i<size;i++)
                dst[i]=src[i];
}


__shared__ char int_to_char_map[10];
__device__ void init_int_to_char_map()
{
  int_to_char_map[0]='0'; int_to_char_map[1]='1'; int_to_char_map[2]='2'; int_to_char_map[3]='3'; int_to_char_map[4]='4'; int_to_char_map[5]='5'; int_to_char_map[6]='6'; int_to_char_map[7]='7'; int_to_char_map[8]='8'; int_to_char_map[9]='9';
}

__device__ void print_uint(char* tgt, int input, int *len){
        if (input<10) {tgt[0]=int_to_char_map[input]; tgt[1]=0; *len=1; return;}
        char count=0;
        while(input>0)
        {
                tgt[count]=int_to_char_map[input%10];
                count++;
                input/=10;
        }
        *len=count;
        count--;
        char reverse=0;
        while(count>0)
        {
                char tmp=tgt[count];
                tgt[count]=tgt[reverse];
                count--;
                tgt[reverse]=tmp;
                reverse++;
        }
}


__device__ volatile char* get_row(volatile uchar** cur_page_ptr, size_t* cur_page_offset, size_t req_file_offset, int max_file_size, int fd, int type)
{
        if (*cur_page_ptr!=NULL && *cur_page_offset+FS_BLOCKSIZE>req_file_offset)
                return (volatile char*)(*cur_page_ptr+(req_file_offset&(FS_BLOCKSIZE-1)));

        // remap
        if (*cur_page_ptr && gmunmap(*cur_page_ptr,0)) ERROR("Unmap failed");

        int mapsize=(max_file_size-req_file_offset)>FS_BLOCKSIZE?FS_BLOCKSIZE:(max_file_size-req_file_offset);

        *cur_page_offset=(req_file_offset& (~(FS_BLOCKSIZE-1)));// round to the beg. of the page
        *cur_page_ptr=(volatile uchar*) gmmap(NULL, mapsize,0,type, fd,*cur_page_offset);
        if (*cur_page_ptr == GMAP_FAILED) ERROR("MMAP failed");

        return (volatile char*)(*cur_page_ptr+(req_file_offset&(FS_BLOCKSIZE-1)));
}
struct _pagehelper{
        volatile uchar* page;
        size_t file_offset;
};

//#define alpha(src)      (((src)>=65 && (src)<=90)||( (src)>=97 && (src)<=122)|| (src)==95 || (src)==39)
#define alpha(src)      (((src)>=65 && (src)<=90)||( (src)>=97 && (src)<=122)|| (src)==95)
#define INPUT_PREFETCH_ARRAY (128*33)
#define INPUT_PREFETCH_SIZE (128*32)

#define CORPUS_PREFETCH_SIZE (16384)

__shared__ char input[INPUT_PREFETCH_ARRAY];

__shared__ char corpus[CORPUS_PREFETCH_SIZE+32+1]; // just in case we need the leftovers

__device__ int find_overlap(char* dst)
{
  __shared__ int res;
  if(threadIdx.x==0){
    res=0;
    int i=0;
    for(;i<32&&alpha(dst[i]);i++);
    res=i;
  }
  __syncthreads();
  return res;

}



__device__ void prefetch_banks(char *dst, volatile char *src, int data_size, int total_buf)
{
  __syncthreads();
  int i=0;

  for(i=threadIdx.x;i<data_size;i+=blockDim.x)
  {
    int offset=(i>>5)*33+(i&31);
    dst[offset]=src[i];
  }
  for(;i<total_buf;i+=blockDim.x) {
    int offset=(i>>5)*33+(i&31);
    dst[offset]=0;
  }
  __syncthreads();
}

__device__ void prefetch(char *dst, volatile char *src, int data_size, int total_buf)
{
  __syncthreads();
  int i=0;
  for(i=threadIdx.x;i<data_size;i+=blockDim.x)
  {
    dst[i]=src[i];
  }
  for(;i<total_buf;i+=blockDim.x) dst[i]=0;
  __syncthreads();
}
#define WARP_COPY(dst,src) (dst)[threadIdx.x&31]=(src)[threadIdx.x&31];
#define LEN_ZERO (-1)
#define NO_MATCH 0
#define MATCH  1


__device__ int match_string( char* a, char*data, int data_size, char* wordlen)
{
  int matches=0;
  char sizecount=0;
  char word_start=1;
  if (*a==0) return -1;

  for(int i=0;i<data_size;i++)
  {
    if (!alpha(data[i])) {
      if ((sizecount == 32 || a[sizecount]=='\0' ) && word_start ) { matches++; *wordlen=sizecount;}
      word_start=1;
      sizecount=0;
    }else{

      if (a[sizecount]==data[i]) { sizecount++; }
      else {  word_start=0;  sizecount=0;}
    }
  }

  return matches;
}
__device__ int d_dbg;
__shared__ char current_db_name[FILENAME_SIZE+1];
__device__ char* get_next(char* str, char** next, int* db_strlen){
  __shared__ int beg;
  __shared__ int i;
  char db_name_ptr=0;
  if (str[0]=='\0') return NULL;

  BEGIN_SINGLE_THREAD
  beg=-1;
  for(i=0; (str[i]==' '||str[i]=='\t'||str[i]==','||str[i]=='\r'||str[i]=='\n');i++);
  beg=i;
  for(;str[i]!='\n' && str[i]!='\r' && str[i]!='\0' && str[i]!=',' && i<64 ;i++,db_name_ptr++)
    current_db_name[db_name_ptr]=str[i];

  current_db_name[db_name_ptr]='\0';
  *db_strlen=i-beg;

  END_SINGLE_THREAD

  if (i-beg==64) return NULL;
  if (i-beg==0) return NULL;

  *next=&str[i+1];
  return current_db_name;
}

#define ROW_SIZE (128*32)
#define PREFETCH_SIZE 16384

struct context {
    int zfd_src;
    int zfd_dbs;
    int zfd_o;
    char* output_buffer;
    char* input_tmp;
    char* db_files;
    int to_read;
};

__shared__ int output_count;
__device__ int global_output;


__device__ void process_one_db(struct context ctx, char* previous_db);

__device__ void process_one_chunk_in_db(struct context ctx, char* current_db, char* next_db, int zfd_db, size_t _cursor, size_t db_size, int db_strlen) {
    if (_cursor < db_size) {
        bool last_iter=db_size-_cursor<(CORPUS_PREFETCH_SIZE+32);
        int db_left=last_iter?db_size-_cursor: CORPUS_PREFETCH_SIZE+32;

        corpus[db_left]='\0';
        gloop::read(zfd_db,_cursor,db_left,(uchar*)corpus, [=](size_t bytes_read) {
            if(bytes_read!=db_left) ERROR("Failed to read DB file");


            // take care of the stitches
            int overlap=0;

            auto next = [=](size_t _cursor) {
                __syncthreads();

                /// how many did we find
                if(threadIdx.x==0){
                    output_count=0;
                }
                __syncthreads();
                process_one_chunk_in_db(ctx, current_db, next_db, zfd_db, _cursor, db_size, db_strlen);
            };

            size_t next_cursor = _cursor;
            if(!last_iter){
                overlap=find_overlap(corpus+CORPUS_PREFETCH_SIZE);
                next_cursor+=overlap;
            }
            next_cursor+=CORPUS_PREFETCH_SIZE;
            ///////////////////// NOW WE ARE DEALING WITH THE INPUT
            //
            // indexing is in chars, not in row size
            for(int input_block=0;input_block<ctx.to_read;input_block+=INPUT_PREFETCH_SIZE){
                int data_left=ctx.to_read-input_block;

                prefetch_banks(input,ctx.input_tmp + input_block,min(data_left,INPUT_PREFETCH_SIZE),INPUT_PREFETCH_SIZE);

                char word_size=0;
                int res= match_string(input+threadIdx.x*33,corpus,last_iter?db_left+1:CORPUS_PREFETCH_SIZE+overlap+1,&word_size);

                if (!__syncthreads_or(res!=LEN_ZERO && res )) continue;

                if(res!=LEN_ZERO && res ){
                    char numstr[4]; int numlen;
                    print_uint(numstr,res,&numlen);

                    int offset=atomicAdd(&output_count,(numlen+1+word_size+1+db_strlen+1));

                    char* outptr=ctx.output_buffer+offset;
                    memcpy_thread(outptr, input+threadIdx.x*33,word_size);
                    outptr[word_size]=' ';

                    memcpy_thread(outptr+word_size+1,numstr,numlen);
                    outptr[word_size+numlen+1]=' ';

                    memcpy_thread(outptr+word_size+numlen+2,current_db,db_strlen);
                    outptr[word_size+numlen+db_strlen+2]='\n';
                }
                __syncthreads();
                if (output_count){
                    __shared__ int old_offset;
                    if (threadIdx.x==0) old_offset=atomicAdd(&global_output,output_count);
                    __syncthreads();

                    gloop::write(ctx.zfd_o, old_offset, output_count,(uchar*) ctx.output_buffer, [=](size_t written_size) {
                        if (written_size != output_count) ERROR("Write to output failed");
                        next(next_cursor);
                    });
                    return;
                }
                next(next_cursor);
            }
        });
        return;
    }
    gloop::close(zfd_db, [=](int err) {
        BEGIN_SINGLE_THREAD
        output_count=0;
        END_SINGLE_THREAD
        process_one_db(ctx, next_db);
    });
}

__device__ void process_one_db(struct context ctx, char* previous_db)
{
    char* next_db;
    __shared__ int db_strlen;

    if (char* current_db = get_next(previous_db, &next_db, &db_strlen)) {
        gloop::open(current_db,O_GRDONLY, [=](int zfd_db) {
            if (zfd_db<0) ERROR("Failed to open DB file");
            gloop::fstat(zfd_db, [=](size_t db_size) {
                process_one_chunk_in_db(ctx, current_db, next_db, zfd_db, 0, db_size, db_strlen);
            });
        });
        return;
    }

    //we are done.
    //write the output and finish
    gloop::close(ctx.zfd_src, [=](int err) {
        gloop::close(ctx.zfd_dbs, [=](int err) {
            gloop::close(ctx.zfd_o, [=](int err) {
                BEGIN_SINGLE_THREAD
                {
                    free(ctx.output_buffer);
                    free(ctx.input_tmp);
                    free(ctx.db_files);
                }
                END_SINGLE_THREAD
            });
        });
    });
}

void __global__ grep_text(char* src, char* out, char* dbs)
{
    gloop::open(dbs,O_GRDONLY, [=](int zfd_dbs) {
        if (zfd_dbs<0) ERROR("Failed to open output");

        gloop::open(out,O_GWRONCE, [=](int zfd_o) {
            if (zfd_o<0) ERROR("Failed to open output");

            gloop::open(src,O_GRDONLY, [=](int zfd_src) {
                if (zfd_src<0) ERROR("Failed to open input");

                gloop::fstat(zfd_src, [=](size_t in_size) {
                    int total_words=in_size/32;

                    if (total_words==0) ERROR("empty input");


                    int words_per_chunk=total_words/gridDim.x;

                    if (words_per_chunk==0) {
                        words_per_chunk=1;
                        if (blockIdx.x>total_words) {
                            words_per_chunk=0;
                        }
                    }



                    if (words_per_chunk==0) {
                        gloop::close(zfd_o, [=](int err) {
                            gloop::close(zfd_src, [=](int err) {
                            });
                        });
                        return;
                    }


                    gloop::fstat(zfd_src, [=](size_t src_size) {
                        int data_to_process=words_per_chunk*32;

                        if (blockIdx.x==gridDim.x-1)
                            data_to_process=src_size-data_to_process*blockIdx.x;

                        __shared__ char* db_files;
                        __shared__ char* input_tmp;
                        __shared__ char *output_buffer;
                        BEGIN_SINGLE_THREAD
                        {
                            init_int_to_char_map();
                            input_tmp=(char*)malloc(data_to_process);
                            assert(input_tmp);
                            output_buffer=(char*)malloc(data_to_process/32*(32+FILENAME_SIZE+sizeof(int)));
                            assert(output_buffer);
                            output_count=0;

                            db_files=(char*) malloc(3*1024*1024);
                            assert(db_files);
                            __shared__ int toInit;
                            toInit=init_lock.try_wait();
                            if (toInit == 1) {
                                global_output=0;
                                single_thread_ftruncate(zfd_o,0);
                                __threadfence();
                                init_lock.signal();
                            }
                        }
                        END_SINGLE_THREAD

                        gloop::fstat(zfd_dbs, [=](size_t dbs_size) {
                            gloop::read(zfd_dbs,0,dbs_size,(uchar*)db_files, [=](size_t db_bytes_read) {
                                if(db_bytes_read!=dbs_size) ERROR("Failed to read dbs");
                                db_files[db_bytes_read]='\0';

                                int to_read=min(data_to_process,(int)src_size);
                                gloop::read(zfd_src,blockIdx.x*words_per_chunk*32,to_read,(uchar*)input_tmp, [=](size_t bytes_read) {
                                    if (bytes_read!=to_read) ERROR("FAILED to read input");
                                    struct context ctx {
                                        zfd_src,
                                        zfd_dbs,
                                        zfd_o,
                                        output_buffer,
                                        input_tmp,
                                        db_files,
                                        to_read,
                                    };

                                    process_one_db(ctx, db_files);
                                });
                            });
                        });
                    });
                });
            });
        });
    });
}


void init_device_app()
{
    CUDA_SAFE_CALL(cudaDeviceSetLimit(cudaLimitMallocHeapSize,1<<30));
}

void init_app()
{
    // INITI LOCK
    void* inited;

    CUDA_SAFE_CALL(cudaGetSymbolAddress(&inited,init_lock));
    CUDA_SAFE_CALL(cudaMemset(inited,0,sizeof(INIT_LOCK)));

    CUDA_SAFE_CALL(cudaGetSymbolAddress(&inited,last_lock));
    CUDA_SAFE_CALL(cudaMemset(inited,0,sizeof(LAST_SEMAPHORE)));
}

double post_app(double total_time, float trials )
{
    return 0;
    //return  sizeof(float)*VEC_FLOAT*((double)VEC_FLOAT)*2/ (total_time/trials);
}
