/* =====================================================================
 * bench.c  -  Laboratorio: medindo CPU de verdade
 *             (frequencia, CPI/IPC, latencia de instrucao e memoria)
 *
 * Infraestrutura de Hardware / CESAR School
 * Maciel, Ronierison
 *
 * Roda em Linux, WSL2 e Windows. NAO precisa de root, de admin nem de PMU.
 *
 * Ideia central:
 *   Uma cadeia de somas inteiras DEPENDENTES (add reg,reg) custa
 *   exatamente 1 ciclo por soma em qualquer x86-64 ou ARM64 moderno.
 *   Logo  frequencia_real = numero_de_somas / tempo.
 *   O subcomando 'calib' confirma a premissa medindo instrucoes de
 *   latencia conhecida (imul = 3, divsd = 13..20 ciclos).
 *
 * Build (Linux/WSL):
 *   gcc -O2 -fno-tree-vectorize -fno-unroll-loops -o bench bench.c -lm
 * Build do .exe a partir do WSL (roda no Windows sem admin):
 *   x86_64-w64-mingw32-gcc -O2 -fno-tree-vectorize -fno-unroll-loops \
 *       -o bench.exe bench.c
 *
 * Uso: ./bench <subcomando>
 *   info          CPU, timers e caches
 *   calib         valida o metodo contra latencias conhecidas
 *   freq          frequencia REAL do nucleo sob carga
 *   ladder [seg]  frequencia amostrada ao longo do tempo (CSV no stdout)
 *   ilp           IPC x numero de cadeias independentes
 *   lat           latencia, em ciclos, por tipo de instrucao
 *   mem           latencia de memoria por tamanho do working set
 *   matriz [N]    percurso por linha x por coluna, em ciclos/elemento
 *   all           bateria completa
 * ===================================================================== */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

/* ---------------- plataforma ---------------- */
#if defined(_WIN32) || defined(_WIN64)
  #define PLAT_WINDOWS 1
  #include <windows.h>
#else
  #define PLAT_POSIX 1
  #include <unistd.h>
  #include <time.h>
  #ifdef __linux__
    #include <sched.h>
  #endif
#endif

#if defined(__GNUC__) && (defined(__x86_64__) || defined(_M_X64))
  #define ASM_X86 1
  #include <x86intrin.h>
#elif defined(__GNUC__) && defined(__aarch64__)
  #define ASM_ARM64 1
#endif

#define UNROLL 8   /* operacoes por iteracao do laco */

/* =====================================================================
 * 1. Relogios e afinidade
 * ===================================================================== */

static double now_ns(void)
{
#ifdef PLAT_WINDOWS
    static LARGE_INTEGER f;
    static int init = 0;
    LARGE_INTEGER c;
    if (!init) { QueryPerformanceFrequency(&f); init = 1; }
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e9 / (double)f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
#endif
}

/* TSC: conta em frequencia FIXA de referencia, nao na frequencia do nucleo.
 * Serve para medir tempo, nunca para medir ciclos de execucao. */
static uint64_t rdtsc_now(void)
{
#ifdef ASM_X86
    return __rdtsc();
#else
    return 0;
#endif
}

/* Fixa o processo em um nucleo logico. Nao exige privilegio. */
static int pin_cpu(int cpu)
{
#ifdef PLAT_WINDOWS
    DWORD_PTR mask = ((DWORD_PTR)1) << cpu;
    return SetThreadAffinityMask(GetCurrentThread(), mask) ? 0 : -1;
#elif defined(__linux__)
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return sched_setaffinity(0, sizeof(set), &set);
#else
    (void)cpu; return -1;
#endif
}

/* =====================================================================
 * 2. Cadeias de dependencia
 *
 * ATENCAO: usamos "add reg,reg" e NAO "add $1,reg".
 * Nucleos Intel recentes (Golden Cove e sucessores) colapsam cadeias de
 * add com operando imediato e entregam mais de 3 somas por ciclo, o que
 * destroi a premissa de 1 ciclo por soma. Com registrador a dependencia
 * e real. O subcomando 'calib' verifica isso na maquina do aluno.
 * ===================================================================== */

#if defined(ASM_X86)

#define MK_DEP1(NAME, INSN)                                          \
static uint64_t NAME(uint64_t n) {                                   \
    uint64_t a = 1, b = 1;                                           \
    __asm__ __volatile__(                                            \
        "1:\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"      \
        INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"               \
        "subq $1, %[n]\n\t" "jnz 1b\n\t"                             \
        : [a] "+r"(a), [n] "+r"(n) : [b] "r"(b) : "cc");             \
    return a; }

MK_DEP1(chain1,   "addq %[b], %[a]")          /* referencia: 1 ciclo   */
MK_DEP1(lat_addi, "addq $1, %[a]")            /* add com imediato      */
MK_DEP1(lat_imul, "imulq $3, %[a], %[a]")     /* esperado: 3 ciclos    */
MK_DEP1(lat_lea,  "leaq 1(%[a]), %[a]")       /* esperado: 1..2 ciclos */

static uint64_t chain2(uint64_t n) {
    uint64_t a=1,c=2,b=1;
    __asm__ __volatile__(
        "1:\n\t"
        "addq %[b],%[a]\n\taddq %[b],%[c]\n\taddq %[b],%[a]\n\taddq %[b],%[c]\n\t"
        "addq %[b],%[a]\n\taddq %[b],%[c]\n\taddq %[b],%[a]\n\taddq %[b],%[c]\n\t"
        "subq $1,%[n]\n\tjnz 1b\n\t"
        : [a]"+r"(a),[c]"+r"(c),[n]"+r"(n) : [b]"r"(b) : "cc");
    return a+c;
}
static uint64_t chain4(uint64_t n) {
    uint64_t a=1,c=2,d=3,e=4,b=1;
    __asm__ __volatile__(
        "1:\n\t"
        "addq %[b],%[a]\n\taddq %[b],%[c]\n\taddq %[b],%[d]\n\taddq %[b],%[e]\n\t"
        "addq %[b],%[a]\n\taddq %[b],%[c]\n\taddq %[b],%[d]\n\taddq %[b],%[e]\n\t"
        "subq $1,%[n]\n\tjnz 1b\n\t"
        : [a]"+r"(a),[c]"+r"(c),[d]"+r"(d),[e]"+r"(e),[n]"+r"(n) : [b]"r"(b) : "cc");
    return a+c+d+e;
}
static uint64_t chain8(uint64_t n) {
    uint64_t a=1,c=2,d=3,e=4,f=5,g=6,h=7,i=8,b=1;
    __asm__ __volatile__(
        "1:\n\t"
        "addq %[b],%[a]\n\taddq %[b],%[c]\n\taddq %[b],%[d]\n\taddq %[b],%[e]\n\t"
        "addq %[b],%[f]\n\taddq %[b],%[g]\n\taddq %[b],%[h]\n\taddq %[b],%[i]\n\t"
        "subq $1,%[n]\n\tjnz 1b\n\t"
        : [a]"+r"(a),[c]"+r"(c),[d]"+r"(d),[e]"+r"(e),[f]"+r"(f),
          [g]"+r"(g),[h]"+r"(h),[i]"+r"(i),[n]"+r"(n) : [b]"r"(b) : "cc");
    return a+c+d+e+f+g+h+i;
}

/* Ponto flutuante (double). x*x, x/x e sqrt(x) mantem x == 1.0. */
#define MK_FP(NAME, INSN)                                            \
static double NAME(uint64_t n) {                                     \
    double x = 1.0;                                                  \
    __asm__ __volatile__(                                            \
        "1:\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"      \
        INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"               \
        "subq $1, %[n]\n\t" "jnz 1b\n\t"                             \
        : [x] "+x"(x), [n] "+r"(n) : : "cc");                        \
    return x; }

MK_FP(lat_fmul,  "mulsd %[x], %[x]")    /* esperado: 4..5 ciclos   */
MK_FP(lat_fdiv,  "divsd %[x], %[x]")    /* esperado: 13..20 ciclos */
MK_FP(lat_fsqrt, "sqrtsd %[x], %[x]")   /* esperado: 13..20 ciclos */

static double lat_fadd(uint64_t n) {
    double x = 1.0, z = 0.0;
    __asm__ __volatile__(
        "1:\n\t"
        "addsd %[z],%[x]\n\taddsd %[z],%[x]\n\taddsd %[z],%[x]\n\taddsd %[z],%[x]\n\t"
        "addsd %[z],%[x]\n\taddsd %[z],%[x]\n\taddsd %[z],%[x]\n\taddsd %[z],%[x]\n\t"
        "subq $1,%[n]\n\tjnz 1b\n\t"
        : [x]"+x"(x), [n]"+r"(n) : [z]"x"(z) : "cc");
    return x;
}
#define TEM_LATENCIAS 1

#elif defined(ASM_ARM64)

#define MK_DEP1(NAME, INSN)                                          \
static uint64_t NAME(uint64_t n) {                                   \
    uint64_t a = 1, b = 1;                                           \
    __asm__ __volatile__(                                            \
        "1:\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"      \
        INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"               \
        "subs %[n], %[n], #1\n\t" "b.ne 1b\n\t"                      \
        : [a] "+r"(a), [n] "+r"(n) : [b] "r"(b) : "cc");             \
    return a; }

MK_DEP1(chain1,   "add %[a], %[a], %[b]")

static uint64_t chain2(uint64_t n) {
    uint64_t a=1,c=2,b=1;
    __asm__ __volatile__(
        "1:\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "subs %[n],%[n],#1\n\tb.ne 1b\n\t"
        : [a]"+r"(a),[c]"+r"(c),[n]"+r"(n) : [b]"r"(b) : "cc");
    return a+c;
}
static uint64_t chain4(uint64_t n) {
    uint64_t a=1,c=2,d=3,e=4,b=1;
    __asm__ __volatile__(
        "1:\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "add %[d],%[d],%[b]\n\tadd %[e],%[e],%[b]\n\t"
        "add %[a],%[a],%[b]\n\tadd %[c],%[c],%[b]\n\t"
        "add %[d],%[d],%[b]\n\tadd %[e],%[e],%[b]\n\t"
        "subs %[n],%[n],#1\n\tb.ne 1b\n\t"
        : [a]"+r"(a),[c]"+r"(c),[d]"+r"(d),[e]"+r"(e),[n]"+r"(n) : [b]"r"(b) : "cc");
    return a+c+d+e;
}
static uint64_t chain8(uint64_t n) { return chain4(n); }

#else   /* ---- fallback generico: compila em qualquer lugar, menos preciso ---- */

static volatile uint64_t g_sink;
static uint64_t chain1(uint64_t n) {
    uint64_t a = 1; volatile uint64_t b = 1;
    for (uint64_t i = 0; i < n; i++) {
        a += b; a += b; a += b; a += b;
        a += b; a += b; a += b; a += b;
    }
    g_sink = a; return a;
}
static uint64_t chain2(uint64_t n) { return chain1(n); }
static uint64_t chain4(uint64_t n) { return chain1(n); }
static uint64_t chain8(uint64_t n) { return chain1(n); }

#endif

/* Barreira de otimizacao: impede o compilador de "adivinhar" o resultado
 * do laco e apaga-lo. Custa zero instrucao, so amarra o registrador.
 * Sem isso o GCC elimina o laco de divisao inteira por completo. */
#if defined(__GNUC__)
  #define BARREIRA(x) __asm__ __volatile__("" : "+r"(x))
#else
  #define BARREIRA(x) do { } while (0)
#endif

/* Divisao inteira em C puro: vale para qualquer arquitetura. */
static uint64_t lat_idiv(uint64_t n)
{
    volatile uint64_t sink = 0;
    uint64_t a = 1000003, i;
    for (i = 0; i < n; i++) {
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
        a = (4294967291ULL + i) / (a|1) + 1000003; BARREIRA(a);
    }
    sink = a; return sink;
}

/* =====================================================================
 * 3. Frequencia
 * ===================================================================== */

static uint64_t calibrate(double alvo_ms)
{
    uint64_t it = 200000;
    for (;;) {
        double t0 = now_ns();
        chain1(it);
        double dt = (now_ns() - t0) / 1e6;
        if (dt >= alvo_ms) return it;
        if (dt < 0.05) { it *= 8; continue; }
        double f = alvo_ms / dt;
        if (f > 50) f = 50;
        it = (uint64_t)(it * f) + 1;
        if (it > (uint64_t)4e10) return it;
    }
}

typedef struct { double ghz, tsc_ghz, secs; } freq_result;

static freq_result measure_freq(double janela_ms)
{
    freq_result r; r.ghz = r.tsc_ghz = r.secs = 0.0;
    uint64_t it = calibrate(janela_ms);
    uint64_t c0 = rdtsc_now();
    double t0 = now_ns();
    chain1(it);
    double t1 = now_ns();
    uint64_t c1 = rdtsc_now();
    double s = (t1 - t0) / 1e9;
    r.secs = s;
    r.ghz = (double)(it * UNROLL) / s / 1e9;
    r.tsc_ghz = (c1 > c0) ? (double)(c1 - c0) / s / 1e9 : 0.0;
    return r;
}

static void warmup(int ms)
{
    double t0 = now_ns();
    while ((now_ns() - t0) / 1e6 < ms) chain1(2000000);
}

static double ghz_estavel(void)
{
    warmup(400);
    double v[3];
    v[0] = measure_freq(250).ghz;
    v[1] = measure_freq(250).ghz;
    v[2] = measure_freq(250).ghz;
    for (int i=0;i<3;i++) for (int j=i+1;j<3;j++)
        if (v[j] < v[i]) { double t=v[i]; v[i]=v[j]; v[j]=t; }
    return v[1];   /* mediana: descarta a amostra contaminada por ruido */
}

static double ciclos_por_op_u64(uint64_t (*fn)(uint64_t), double ghz, double alvo_ms)
{
    uint64_t it = calibrate(alvo_ms);
    fn(it/8 + 1);
    double t0 = now_ns(); fn(it); double s = (now_ns()-t0)/1e9;
    return s * ghz * 1e9 / (double)(it * UNROLL);
}
#ifdef TEM_LATENCIAS
static double ciclos_por_op_f64(double (*fn)(uint64_t), double ghz, double alvo_ms)
{
    uint64_t it = calibrate(alvo_ms) / 4 + 1;
    fn(it/8 + 1);
    double t0 = now_ns(); fn(it); double s = (now_ns()-t0)/1e9;
    return s * ghz * 1e9 / (double)(it * UNROLL);
}
#endif

/* =====================================================================
 * 4. Memoria: pointer chasing
 * ===================================================================== */

static double chase(size_t bytes, double ghz, uint64_t passos)
{
    const size_t LINE = 64, PTRS = LINE / sizeof(void*);
    size_t n = bytes / LINE;
    if (n < 16) n = 16;

    void **buf = (void **)malloc(n * LINE);
    if (!buf) return -1.0;
    memset(buf, 0, n * LINE);
    size_t *perm = (size_t *)malloc(n * sizeof(size_t));
    if (!perm) { free(buf); return -1.0; }
    for (size_t i = 0; i < n; i++) perm[i] = i;

    uint64_t s = 88172645463325252ULL;
    for (size_t i = n - 1; i > 0; i--) {
        s ^= s<<13; s ^= s>>7; s ^= s<<17;
        size_t j = (size_t)(s % (i + 1));
        size_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
    }
    for (size_t i = 0; i < n; i++)
        buf[perm[i]*PTRS] = &buf[perm[(i+1)%n]*PTRS];

    void **p = &buf[perm[0]*PTRS];
    for (uint64_t i = 0; i < n*2; i++) p = (void**)*p;      /* aquece */

    double t0 = now_ns();
    for (uint64_t i = 0; i < passos; i++) p = (void**)*p;
    double t1 = now_ns();
    { void * volatile sink = p; (void)sink; }   /* impede a eliminacao do laco */
    free(perm); free(buf);
    return (t1 - t0) / (double)passos * ghz;   /* ns * ciclos/ns */
}

/* =====================================================================
 * 5. Matriz
 * ===================================================================== */

#if defined(__GNUC__)
  #define NOINLINE __attribute__((noinline))
#else
  #define NOINLINE
#endif

static NOINLINE double soma_por_linha(const double *m, int N)
{
    double s = 0.0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            s += m[(size_t)i*N + j];
    return s;
}
static NOINLINE double soma_por_coluna(const double *m, int N)
{
    double s = 0.0;
    for (int j = 0; j < N; j++)
        for (int i = 0; i < N; i++)
            s += m[(size_t)i*N + j];
    return s;
}

/* =====================================================================
 * 6. Subcomandos
 * ===================================================================== */

static void hr(void) { printf("  ----------------------------------------"
                              "----------------------------\n"); }

static void cmd_info(void)
{
    printf("\n== INFORMACOES DA MAQUINA ==\n");
#ifdef PLAT_WINDOWS
    SYSTEM_INFO si; GetSystemInfo(&si);
    LARGE_INTEGER f; QueryPerformanceFrequency(&f);
    printf("  CPUs logicas         : %lu\n", (unsigned long)si.dwNumberOfProcessors);
    printf("  QueryPerformanceFreq : %lld Hz\n", (long long)f.QuadPart);
#else
    printf("  CPUs logicas         : %ld\n", sysconf(_SC_NPROCESSORS_ONLN));
    struct timespec res; clock_getres(CLOCK_MONOTONIC, &res);
    printf("  Resolucao do relogio : %ld ns\n", (long)res.tv_nsec);
    {
        FILE *fp = fopen("/proc/cpuinfo", "r");
        if (fp) {
            char l[512]; int ok = 0;
            while (fgets(l, sizeof l, fp))
                if (!ok && strncmp(l, "model name", 10) == 0) {
                    char *c = strchr(l, ':');
                    if (c) { printf("  Modelo               : %s", c+2); ok = 1; }
                }
            fclose(fp);
        }
    }
  #ifdef _SC_LEVEL1_DCACHE_SIZE
    printf("  L1d / L2 / L3 (KiB)  : %ld / %ld / %ld\n",
           sysconf(_SC_LEVEL1_DCACHE_SIZE)/1024,
           sysconf(_SC_LEVEL2_CACHE_SIZE)/1024,
           sysconf(_SC_LEVEL3_CACHE_SIZE)/1024);
  #endif
#endif
#if defined(ASM_X86)
    printf("  Metodo de medicao    : assembly x86-64 (preciso)\n");
#elif defined(ASM_ARM64)
    printf("  Metodo de medicao    : assembly ARM64 (preciso)\n");
#else
    printf("  Metodo de medicao    : C portavel (APROXIMADO, ver roteiro)\n");
#endif
    printf("\n");
}

/* Valida o instrumento antes de confiar nele. */
static int cmd_calib(double ghz)
{
    int ok = 1;
    printf("== CALIBRACAO: o instrumento e confiavel? ==\n");
    printf("  Assumimos que 'add reg,reg' dependente custa 1 ciclo e obtivemos\n"
           "  %.3f GHz. Agora medimos instrucoes de latencia CONHECIDA.\n"
           "  Se os valores baterem, a premissa se sustenta.\n\n", ghz);
    printf("  instrucao         | medido |  esperado | veredito\n");
    hr();
#ifdef TEM_LATENCIAS
    {
        double c1 = ciclos_por_op_u64(lat_imul, ghz, 150);
        double c2 = ciclos_por_op_f64(lat_fdiv, ghz, 150);
        int b1 = (c1 >= 2.5 && c1 <= 3.8);
        int b2 = (c2 >= 10.0 && c2 <= 26.0);
        ok = b1 && b2;
        printf("  %-17s | %6.2f | %9s | %s\n", "imul  (int64)",  c1, "3",
               b1 ? "OK" : "FORA DA FAIXA");
        printf("  %-17s | %6.2f | %9s | %s\n", "divsd (float64)", c2, "13-20",
               b2 ? "OK" : "FORA DA FAIXA");
    }
#else
    printf("  (calibracao automatica disponivel apenas em x86-64)\n");
#endif
    hr();
    if (ok) printf("  VEREDITO: medicao valida. Use %.3f GHz como referencia.\n\n", ghz);
    else    printf("  VEREDITO: houve interferencia. Feche outros programas, use\n"
                   "            taskset e repita. Veja a secao Armadilhas do roteiro.\n\n");
    return ok;
}

static void cmd_freq(void)
{
    printf("== FREQUENCIA REAL DO NUCLEO ==\n");
    printf("  metodo: cadeia de somas dependentes (1 soma = 1 ciclo)\n\n");
    warmup(400);
    freq_result a = measure_freq(250), b = measure_freq(250), c = measure_freq(250);
    double med = (a.ghz + b.ghz + c.ghz) / 3.0;
    printf("  amostra 1            : %6.3f GHz\n", a.ghz);
    printf("  amostra 2            : %6.3f GHz\n", b.ghz);
    printf("  amostra 3            : %6.3f GHz\n", c.ghz);
    hr();
    printf("  FREQUENCIA EFETIVA   : %6.3f GHz\n", med);
    if (a.tsc_ghz > 0) {
        printf("  Taxa do TSC          : %6.3f GHz (relogio de referencia fixo)\n", a.tsc_ghz);
        printf("  Razao nucleo / TSC   : %6.3f  (>1 indica turbo)\n", med / a.tsc_ghz);
    }
    if (med > 7.0)
        printf("\n  AVISO: valor implausivel. A cadeia de dependencia foi quebrada.\n"
               "         Rode './bench calib' para diagnosticar.\n");
    printf("\n");
}

static void cmd_ladder(int seg)
{
    double t0;
    fprintf(stderr, "== FREQUENCIA AO LONGO DO TEMPO (%d s) ==\n", seg);
    fprintf(stderr, "   CSV no stdout. Ex.: ./bench ladder 90 > turbo.csv\n\n");
    printf("segundos,ghz\n");
    t0 = now_ns();
    for (;;) {
        double el = (now_ns() - t0) / 1e9;
        if (el > seg) break;
        printf("%.2f,%.4f\n", el, measure_freq(200).ghz);
        fflush(stdout);
    }
}

static void cmd_ilp(double ghz)
{
    uint64_t it;
    int i;
    struct { const char *n; uint64_t (*f)(uint64_t); } t[4];
    t[0].n="1"; t[0].f=chain1; t[1].n="2"; t[1].f=chain2;
    t[2].n="4"; t[2].f=chain4; t[3].n="8"; t[3].f=chain8;

    printf("== ILP: MESMAS INSTRUCOES, CPI DIFERENTE ==\n");
    printf("  8 somas por iteracao, distribuidas em N cadeias independentes\n\n");
    printf("  cadeias | CPI (ciclos/soma) | IPC (somas/ciclo)\n");
    hr();
    it = calibrate(250);
    for (i = 0; i < 4; i++) {
        double t0, s, cpi;
        t[i].f(it/8 + 1);
        t0 = now_ns(); t[i].f(it); s = (now_ns()-t0)/1e9;
        cpi = s * ghz * 1e9 / (double)(it * UNROLL);
        printf("  %7s | %17.3f | %17.2f\n", t[i].n, cpi, 1.0/cpi);
    }
    hr();
    printf("  1 cadeia  -> preso na LATENCIA: CPI = 1\n");
    printf("  N cadeias -> preso na VAZAO: CPI < 1, o processador e superescalar\n");
    printf("  O CPI nao e propriedade da instrucao, e da DEPENDENCIA entre elas.\n\n");
}

static void cmd_lat(double ghz)
{
    printf("== LATENCIA POR TIPO DE INSTRUCAO ==\n");
    printf("  cadeia dependente: o tempo medido e a latencia pura\n\n");
    printf("  instrucao              | ciclos | referencia tipica\n");
    hr();
#ifdef TEM_LATENCIAS
    printf("  %-22s | %6.2f | 1\n",     "add reg,reg (int64)", ciclos_por_op_u64(chain1,   ghz, 150));
    printf("  %-22s | %6.2f | 1-2 (*)\n","lea (int64)",        ciclos_por_op_u64(lat_lea,  ghz, 150));
    printf("  %-22s | %6.2f | 3\n",     "imul (int64)",        ciclos_por_op_u64(lat_imul, ghz, 150));
    printf("  %-22s | %6.2f | 2-4\n",   "addsd (float64)",     ciclos_por_op_f64(lat_fadd, ghz, 150));
    printf("  %-22s | %6.2f | 4-5\n",   "mulsd (float64)",     ciclos_por_op_f64(lat_fmul, ghz, 150));
    printf("  %-22s | %6.2f | 13-20\n", "divsd (float64)",     ciclos_por_op_f64(lat_fdiv, ghz, 150));
    printf("  %-22s | %6.2f | 13-20\n", "sqrtsd (float64)",    ciclos_por_op_f64(lat_fsqrt,ghz, 150));
#endif
    printf("  %-22s | %6.2f | 15-90\n", "div inteira (em C)",  ciclos_por_op_u64(lat_idiv, ghz, 12));
    hr();
#ifdef TEM_LATENCIAS
    {
        double ai = ciclos_por_op_u64(lat_addi, ghz, 150);
        printf("  Curiosidade de microarquitetura:\n");
        printf("    add com IMEDIATO (add $1,reg) mediu %.2f ciclos.\n", ai);
        if (ai < 0.85)
            printf("    Menos de 1 ciclo em cadeia dependente e IMPOSSIVEL na teoria.\n"
                   "    Este nucleo colapsa somas de imediatos em tempo de execucao,\n"
                   "    e a linha (*) de lea sofre do mesmo efeito.\n"
                   "    Licao: valide o instrumento antes de confiar nele. Por isso\n"
                   "    todas as medidas usam add reg,reg como referencia.\n");
        else
            printf("    Neste nucleo o comportamento e o esperado (>= 1 ciclo).\n");
    }
#endif
    printf("\n  Conclusao: o CPI medio depende da MISTURA de instrucoes do programa.\n\n");
}

static void cmd_mem(double ghz)
{
    size_t tam[15];
    int i, n;
    tam[0]=8*1024; tam[1]=16*1024; tam[2]=32*1024; tam[3]=64*1024;
    tam[4]=128*1024; tam[5]=256*1024; tam[6]=512*1024;
    tam[7]=1UL<<20; tam[8]=2UL<<20; tam[9]=4UL<<20; tam[10]=8UL<<20;
    tam[11]=16UL<<20; tam[12]=32UL<<20; tam[13]=64UL<<20; tam[14]=128UL<<20;
    n = 15;

    printf("== LATENCIA DE MEMORIA (pointer chasing aleatorio) ==\n");
    printf("  cada acesso depende do anterior: o prefetcher nao consegue ajudar\n\n");
    printf("  working set |  ciclos/acesso |  ns/acesso | nivel provavel\n");
    hr();
    for (i = 0; i < n; i++) {
        uint64_t passos = (tam[i] < (1UL<<20)) ? 20000000ULL : 3000000ULL;
        double cyc = chase(tam[i], ghz, passos);
        const char *niv;
        char lb[24];
        if (cyc < 0) { printf("  (sem memoria para %lu MiB)\n", (unsigned long)(tam[i]>>20)); break; }
        niv = cyc < 8 ? "L1" : cyc < 25 ? "L2" : cyc < 80 ? "L3" : "RAM";
        if (tam[i] >= (1UL<<20)) snprintf(lb, sizeof lb, "%lu MiB", (unsigned long)(tam[i]>>20));
        else                     snprintf(lb, sizeof lb, "%lu KiB", (unsigned long)(tam[i]>>10));
        printf("  %11s | %14.1f | %10.2f | %s\n", lb, cyc, cyc/ghz, niv);
    }
    hr();
    printf("  Os degraus da tabela sao as fronteiras dos caches.\n");
    printf("  Compare com o que 'lscpu --caches' declara.\n\n");
}

static void cmd_matriz(int N, double ghz)
{
    size_t el = (size_t)N * N;
    double *m, tl, tc, t0;
    volatile double sink;

    printf("== MATRIZ: POR LINHA x POR COLUNA (N = %d) ==\n\n", N);
    m = (double *)malloc(el * sizeof(double));
    if (!m) { printf("  falha ao alocar %.1f MiB\n", el*8/1048576.0); return; }
    { size_t i; for (i = 0; i < el; i++) m[i] = 1.0; }
    printf("  memoria da matriz    : %.1f MiB\n\n", el*8/1048576.0);

    t0 = now_ns(); sink = soma_por_linha(m, N);  tl = (now_ns()-t0)/1e9;
    t0 = now_ns(); sink = soma_por_coluna(m, N); tc = (now_ns()-t0)/1e9;
    (void)sink;

    printf("  percurso    |  tempo (s) | ciclos/elemento\n");
    hr();
    printf("  por linha   | %10.4f | %14.2f\n", tl, tl*ghz*1e9/(double)el);
    printf("  por coluna  | %10.4f | %14.2f\n", tc, tc*ghz*1e9/(double)el);
    hr();
    printf("  Razao coluna/linha   : %.2fx\n\n", tc/tl);
    printf("  O laco interno das duas versoes tem 4 e 5 instrucoes por elemento:\n");
    printf("  cerca de 25%% de diferenca na CONTAGEM de instrucoes. O tempo, porem,\n");
    printf("  difere varias vezes mais. Confira com 'make matriz-asm'.\n");
    printf("  Logo a diferenca nao esta no IC, esta no CPI, e todo o CPI extra\n");
    printf("  veio da memoria. Este e o numero que faltava na Aula 01.\n\n");
    free(m);
}

/* =====================================================================
 * 7. main
 * ===================================================================== */

int main(int argc, char **argv)
{
    const char *cmd = (argc > 1) ? argv[1] : "all";
    double ghz;

    setvbuf(stdout, NULL, _IOLBF, 0);

    if (pin_cpu(0) != 0)
        fprintf(stderr, "[aviso] nao consegui fixar a afinidade de CPU\n");

    if (strcmp(cmd, "info") == 0)   { cmd_info(); return 0; }
    if (strcmp(cmd, "freq") == 0)   { cmd_freq(); return 0; }
    if (strcmp(cmd, "ladder") == 0) { warmup(200); cmd_ladder(argc>2?atoi(argv[2]):60); return 0; }

    ghz = ghz_estavel();

    if (strcmp(cmd, "calib") == 0)  { cmd_calib(ghz); return 0; }
    if (strcmp(cmd, "all") == 0) {
        cmd_info(); cmd_freq(); cmd_calib(ghz);
        cmd_ilp(ghz); cmd_lat(ghz); cmd_mem(ghz); cmd_matriz(2048, ghz);
        return 0;
    }

    printf("[frequencia de referencia: %.3f GHz]\n\n", ghz);
    if      (strcmp(cmd,"ilp")==0)    cmd_ilp(ghz);
    else if (strcmp(cmd,"lat")==0)    cmd_lat(ghz);
    else if (strcmp(cmd,"mem")==0)    cmd_mem(ghz);
    else if (strcmp(cmd,"matriz")==0) cmd_matriz(argc>2?atoi(argv[2]):2048, ghz);
    else {
        fprintf(stderr,"uso: %s [info|calib|freq|ladder N|ilp|lat|mem|matriz N|all]\n", argv[0]);
        return 1;
    }
    return 0;
}
