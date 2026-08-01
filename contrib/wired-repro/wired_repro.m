/* Microbenchmark T-023 (Fase E): slot espliciti + pread contro mmap, sotto Metal.
 *
 * Domanda (piano-lavoro-evidenze-turbofieldfare.md, Fase E): durante l'uso GPU,
 * la memoria wired resta limitata agli slot riempiti con pread (architettura
 * TurboFieldfare), o cresce fino all'intera vista mappata (comportamento
 * osservato in DS4 sui layer bypass, T-014)?
 *
 * Due bracci sullo stesso file dati:
 *   pread <file> <n_slot>  — n_slot buffer da 6,75 MiB allineati a pagina
 *                            (posix_memalign), avvolti con newBufferWithBytesNoCopy,
 *                            riempiti con pread paralleli (8 thread) da offset
 *                            sparsi; kernel GPU somma tutti i buffer.
 *   mmap  <file> <n_slot>  — l'intero file mmap-ato e avvolto in UN buffer
 *                            bytesNoCopy (come le "mmap model wrapper spans" di
 *                            DS4); il kernel GPU legge le stesse regioni sparse.
 *
 * Output (una riga JSON): wired di sistema prima/dopo fill/dopo GPU, tempi,
 * checksum (somma a 64 bit dei dati letti — deve coincidere tra i bracci:
 * stesse regioni dello stesso file).
 *
 * Criteri di esito dichiarati nel piano prima della misura; deviazione
 * dichiarata: dati sintetici (il GGUF non è più su disco, 2026-07-31 sera);
 * il comportamento wired del driver non dipende dal contenuto dei byte.
 * Compilazione: clang -O2 -fobjc-arc -framework Metal -framework Foundation
 *               -o microbench_pread_metal microbench_pread_metal.m
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define BLOB (7077888ULL)          /* 6,75 MiB, multiplo di pagina (432 x 16384) */
#define LETTORI 8

static double wired_gib(void) {
    vm_statistics64_data_t vm; mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n);
    return (double)vm.wire_count * vm_page_size / (1ULL << 30);
}

static double ora_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e6; }

/* offset sparsi e deterministici nel file (LCG), allineati al blob */
static void offsets_sparsi(uint64_t *off, int n, uint64_t taglia_file) {
    uint64_t stato = 0x5DEECE66DULL, blocchi = taglia_file / BLOB;
    for (int i = 0; i < n; i++) {
        stato = stato * 6364136223846793005ULL + 1442695040888963407ULL;
        off[i] = (stato % blocchi) * BLOB;
    }
}

typedef struct { int fd; uint64_t off; void *dst; } Lavoro;
static void *lettore(void *arg) {
    Lavoro *l = (Lavoro *)arg;
    ssize_t fatto = 0;
    while (fatto < (ssize_t)BLOB) {
        ssize_t r = pread(l->fd, (char *)l->dst + fatto, BLOB - fatto, l->off + fatto);
        if (r <= 0) { perror("pread"); exit(2); }
        fatto += r;
    }
    return NULL;
}

static uint64_t checksum(const void *p, size_t byte) {
    const uint64_t *v = (const uint64_t *)p; uint64_t s = 0;
    for (size_t i = 0; i < byte / 8; i++) s += v[i];
    return s;
}

static NSString *KERNEL = @""
"#include <metal_stdlib>\n using namespace metal;\n"
"kernel void somma(device const ulong *dati [[buffer(0)]],"
"                  device ulong *parziali [[buffer(1)]],"
"                  constant ulong &n [[buffer(2)]],"
"                  uint gid [[thread_position_in_grid]]) {"
"  ulong s = 0;"
"  for (ulong i = gid * 1024; i < min((ulong)(gid + 1) * 1024, n); i++) s += dati[i];"
"  parziali[gid] = s;"
"}\n";

static uint64_t gpu_somma(id<MTLDevice> dev, id<MTLComputePipelineState> pso,
                          id<MTLCommandQueue> coda, id<MTLBuffer> buf,
                          uint64_t offset_byte, uint64_t byte) {
    uint64_t n = byte / 8, gruppi = (n + 1023) / 1024;
    id<MTLBuffer> parziali = [dev newBufferWithLength:gruppi * 8
                                              options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [coda commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBuffer:buf offset:offset_byte atIndex:0];
    [enc setBuffer:parziali offset:0 atIndex:1];
    [enc setBytes:&n length:8 atIndex:2];
    [enc dispatchThreads:MTLSizeMake(gruppi, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [enc endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    return checksum(parziali.contents, gruppi * 8);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 4) { fprintf(stderr, "uso: %s pread|mmap <file> <n_slot>\n", argv[0]); return 2; }
    const char *modo = argv[1], *percorso = argv[2];
    int n_slot = atoi(argv[3]);
    int fd = open(percorso, O_RDONLY);
    if (fd < 0) { perror("open"); return 2; }
    struct stat st; fstat(fd, &st);
    uint64_t *off = calloc(n_slot, sizeof(uint64_t));
    offsets_sparsi(off, n_slot, (uint64_t)st.st_size);

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:KERNEL options:nil error:&err];
    if (!lib) { fprintf(stderr, "metal: %s\n", err.description.UTF8String); return 2; }
    id<MTLComputePipelineState> pso =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"somma"] error:&err];
    id<MTLCommandQueue> coda = [dev newCommandQueue];

    double w0 = wired_gib(), t0 = ora_ms(), t_fill, w_fill;
    uint64_t somma_gpu = 0, somma_cpu = 0;

    if (strcmp(modo, "pread") == 0) {
        void **slot = calloc(n_slot, sizeof(void *));
        NSMutableArray<id<MTLBuffer>> *buf = [NSMutableArray array];
        for (int i = 0; i < n_slot; i++) {
            if (posix_memalign(&slot[i], 2 * 1024 * 1024, BLOB)) return 2;
            [buf addObject:[dev newBufferWithBytesNoCopy:slot[i] length:BLOB
                                                 options:MTLResourceStorageModeShared
                                             deallocator:nil]];
        }
        for (int base = 0; base < n_slot; base += LETTORI) {  /* pread paralleli */
            pthread_t th[LETTORI]; Lavoro lv[LETTORI]; int k = 0;
            for (; k < LETTORI && base + k < n_slot; k++) {
                lv[k] = (Lavoro){fd, off[base + k], slot[base + k]};
                pthread_create(&th[k], NULL, lettore, &lv[k]);
            }
            while (k--) pthread_join(th[k], NULL);
        }
        t_fill = ora_ms() - t0; w_fill = wired_gib();
        for (int i = 0; i < n_slot; i++) {
            somma_gpu += gpu_somma(dev, pso, coda, buf[i], 0, BLOB);
            somma_cpu += checksum(slot[i], BLOB);
        }
    } else {
        void *mappa = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
        if (mappa == MAP_FAILED) { perror("mmap"); return 2; }
        id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:mappa length:st.st_size
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
        if (!buf) { fprintf(stderr, "bytesNoCopy su mmap rifiutato\n"); return 2; }
        t_fill = ora_ms() - t0; w_fill = wired_gib();   /* nessun fill esplicito */
        for (int i = 0; i < n_slot; i++) {
            somma_gpu += gpu_somma(dev, pso, coda, buf, off[i], BLOB);
            somma_cpu += checksum((char *)mappa + off[i], BLOB);
        }
    }
    double t_gpu = ora_ms() - t0 - t_fill, w_gpu = wired_gib();
    printf("{\"braccio\":\"%s\",\"n_slot\":%d,\"GiB_toccati\":%.2f,"
           "\"wired_prima\":%.2f,\"wired_dopo_fill\":%.2f,\"wired_dopo_gpu\":%.2f,"
           "\"fill_ms\":%.0f,\"gpu_ms\":%.0f,"
           "\"checksum_gpu\":%llu,\"checksum_cpu\":%llu,\"checksum_ok\":%s}\n",
           modo, n_slot, n_slot * (double)BLOB / (1ULL << 30),
           w0, w_fill, w_gpu, t_fill, t_gpu,
           somma_gpu, somma_cpu, somma_gpu == somma_cpu ? "true" : "false");
    return 0;
} }
