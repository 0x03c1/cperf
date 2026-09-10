<#
=======================================================================
 Medir-CPU.ps1
 Laboratorio de medicao de CPU no Windows SEM privilegio de administrador.
 Infraestrutura de Hardware / CESAR School

 Testado em Windows PowerShell 5.1 e PowerShell 7.x.

 Uso:
   powershell -ExecutionPolicy Bypass -File .\Medir-CPU.ps1
   .\Medir-CPU.ps1 -Teste info
   .\Medir-CPU.ps1 -Teste freq
   .\Medir-CPU.ps1 -Teste lat
   .\Medir-CPU.ps1 -Teste ladder -Segundos 90
   .\Medir-CPU.ps1 -Teste tudo -Saida .\resultados

 Subcomandos: info freq calib ilp lat mem matriz ladder tudo

 Dica: se voce editou este arquivo, abra uma janela NOVA do PowerShell antes
 de rodar de novo. O Add-Type nao recompila o motor C# na mesma sessao.

 Se o Windows bloquear o script:
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
 (escopo Process nao exige admin e vale so para esta janela)
=======================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('info','freq','calib','ilp','lat','mem','matriz','ladder','tudo')]
    [string]$Teste = 'tudo',
    [int]$Segundos = 60,
    [int]$Nucleo = 1,
    [string]$Saida = '.\resultados'
)

$ErrorActionPreference = 'Continue'

function Titulo($t) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor Cyan
}
function Nota($t)  { Write-Host "  $t" -ForegroundColor Yellow }
function Bom($t)   { Write-Host "  $t" -ForegroundColor Green }
function Linha     { Write-Host ('  ' + ('-' * 62)) }

# =====================================================================
# 1. Motor de medicao em C#
#
#    O PowerShell interpretado e lento demais para medir ciclos. O
#    Add-Type compila C# de verdade (JIT -> codigo nativo) usando o
#    compilador que ja vem com o Windows. Nao precisa de admin, nao
#    precisa instalar nada.
#
#    Cadeia dependente: 'a += um' com 'um' vindo em tempo de execucao.
#    Em x86-64 o JIT emite 'add rax, rbx', latencia de 1 ciclo, e oito
#    somas dependentes por iteracao custam 8 ciclos.
#
#    O atributo (MethodImplOptions)512 = AggressiveOptimization pula o
#    Tier-0 do JIT no .NET moderno (PowerShell 7). No Windows PowerShell
#    5.1 o bit e ignorado e o .NET Framework ja compila otimizado.
#
#    NOTA sobre ARM (Apple Silicon, Windows on ARM): o JIT ARM64 nem
#    sempre mantem o acumulador em registrador, e a cadeia mede alto
#    demais. O subcomando 'calib' detecta isso. Em maquinas ARM use o
#    'bench' em C (src/bench.c), que forca 'add reg,reg' em assembly.
# =====================================================================
$csharp = @'
using System;
using System.Runtime.CompilerServices;

public static class CpuLab
{
    // ---- cadeia DEPENDENTE: 1 soma = 1 ciclo -------------------------
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static ulong AddChain(long iters, ulong um)
    {
        ulong a = 0;
        for (long i = 0; i < iters; i++)
        {
            a += um; a += um; a += um; a += um;
            a += um; a += um; a += um; a += um;
        }
        return a;
    }

    // ---- cadeia dependente de MULTIPLICACOES: latencia conhecida = 3 --
    // Serve para validar a medicao: mul/add deve dar aproximadamente 3.
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static ulong MulChain(long iters, ulong tres)
    {
        ulong a = 1;
        for (long i = 0; i < iters; i++)
        {
            a *= tres; a *= tres; a *= tres; a *= tres;
            a *= tres; a *= tres; a *= tres; a *= tres;
        }
        return a;
    }

    // ---- cadeia dependente de DIVISOES float: latencia 13 a 20 -------
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static double DivChain(long iters)
    {
        double x = 1.0;
        for (long i = 0; i < iters; i++)
        {
            x = x / x; x = x / x; x = x / x; x = x / x;
            x = x / x; x = x / x; x = x / x; x = x / x;
        }
        return x;
    }

    // ---- cadeia dependente de SOMAS float: latencia 2 a 4 -----------
    // 'zero' vem em tempo de execucao para o JIT nao apagar a soma.
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static double FaddChain(long iters, double zero)
    {
        double x = 1.0;
        for (long i = 0; i < iters; i++)
        {
            x = x + zero; x = x + zero; x = x + zero; x = x + zero;
            x = x + zero; x = x + zero; x = x + zero; x = x + zero;
        }
        return x;
    }

    // ---- cadeia dependente de MULTIPLICACOES float: latencia 4 a 5 ---
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static double FmulChain(long iters)
    {
        double x = 1.0;
        for (long i = 0; i < iters; i++)
        {
            x = x * x; x = x * x; x = x * x; x = x * x;
            x = x * x; x = x * x; x = x * x; x = x * x;
        }
        return x;
    }

    // ---- 4 cadeias INDEPENDENTES: mostra o superescalar --------------
    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static ulong AddChain4(long iters, ulong um)
    {
        ulong a = 0, b = 1, c = 2, d = 3;
        for (long i = 0; i < iters; i++)
        {
            a += um; b += um; c += um; d += um;
            a += um; b += um; c += um; d += um;
        }
        return a + b + c + d;
    }

    // ---- pointer chasing: latencia real de cada nivel de cache -------
    // Um indice por linha de cache (64 bytes = 16 ints).
    public static int[] MontaCiclo(int bytes, int semente)
    {
        int n = bytes / 64; if (n < 16) n = 16;
        int[] a = new int[n * 16];
        int[] perm = new int[n];
        for (int i = 0; i < n; i++) perm[i] = i;

        ulong s = (ulong)semente * 88172645463325252UL + 1;
        for (int i = n - 1; i > 0; i--)
        {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
            int j = (int)(s % (ulong)(i + 1));
            int t = perm[i]; perm[i] = perm[j]; perm[j] = t;
        }
        for (int i = 0; i < n; i++)
            a[perm[i] * 16] = perm[(i + 1) % n] * 16;
        return a;
    }

    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static int Chase(int[] a, long passos)
    {
        int p = 0;
        for (long i = 0; i < passos; i++) p = a[p];
        return p;
    }

    // ---- matriz: por linha x por coluna ------------------------------
    public static double[] NovaMatriz(int n)
    {
        double[] m = new double[(long)n * n];
        for (long i = 0; i < m.LongLength; i++) m[i] = 1.0;
        return m;
    }

    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static double PorLinha(double[] m, int n)
    {
        double s = 0.0;
        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                s += m[(long)i * n + j];
        return s;
    }

    [MethodImpl(MethodImplOptions.NoInlining | (MethodImplOptions)512)]
    public static double PorColuna(double[] m, int n)
    {
        double s = 0.0;
        for (int j = 0; j < n; j++)
            for (int i = 0; i < n; i++)
                s += m[(long)i * n + j];
        return s;
    }
}
'@

if (-not ('CpuLab' -as [type])) {
    Add-Type -TypeDefinition $csharp -Language CSharp
}

# Get-CimInstance so existe no Windows. Fora dele (ou sem o modulo CIM) as
# consultas WMI sao puladas e o laboratorio segue so com o metodo por software.
$script:PodeCim = $null -ne (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)

# =====================================================================
# 2. Preparacao do processo
# =====================================================================
function Preparar-Processo {
    $p = Get-Process -Id $PID
    $maxNucleo = [Environment]::ProcessorCount - 1
    if ($Nucleo -gt $maxNucleo -or $Nucleo -lt 0) {
        Nota "Nucleo $Nucleo nao existe. Usando 0."
        $script:Nucleo = 0
    }
    try {
        # Afinidade: prende o processo em um nucleo. Reduz muito o ruido.
        # Mascara de bits: nucleo 0 = 1, nucleo 1 = 2, nucleo 2 = 4, ...
        $p.ProcessorAffinity = [IntPtr]([int][Math]::Pow(2, $Nucleo))
        Bom "Afinidade fixada no nucleo logico $Nucleo"
    } catch { Nota "Nao consegui fixar a afinidade: $($_.Exception.Message)" }
    try {
        # 'High' e permitido para usuario comum. 'RealTime' exigiria admin.
        $p.PriorityClass = 'High'
        Bom "Prioridade do processo elevada para High (nao exige admin)"
    } catch { Nota "Nao consegui elevar a prioridade: $($_.Exception.Message)" }
}

$SW = [System.Diagnostics.Stopwatch]
function Cronometrar([scriptblock]$bloco) {
    $s = $SW::StartNew(); & $bloco | Out-Null; $s.Stop()
    return $s.Elapsed.TotalSeconds
}

# Aquece o JIT: com poucas chamadas o metodo ainda roda em codigo tier0,
# nao otimizado, e a medicao sai errada.
function Aquecer-JIT {
    for ($i = 0; $i -lt 40; $i++) {
        [CpuLab]::AddChain(200, 1)  | Out-Null
        [CpuLab]::AddChain4(200, 1) | Out-Null
        [CpuLab]::MulChain(200, 3)  | Out-Null
        [CpuLab]::DivChain(200)     | Out-Null
    }
}

# Aquece o turbo: tira a CPU do estado ocioso antes de medir.
function Aquecer-Turbo([int]$ms = 400) {
    $r = $SW::StartNew()
    while ($r.Elapsed.TotalMilliseconds -lt $ms) { [CpuLab]::AddChain(2000000, 1) | Out-Null }
    $r.Stop()
}

# Calibra quantas iteracoes gastam aproximadamente o tempo alvo.
function Calibrar([double]$alvoMs = 250) {
    $it = 200000L
    while ($true) {
        $s = Cronometrar { [CpuLab]::AddChain($it, 1) }
        $ms = $s * 1000
        if ($ms -ge $alvoMs) { return $it }
        if ($ms -lt 0.5) { $it = $it * 8; continue }
        $f = [Math]::Min(50, $alvoMs / $ms)
        $it = [long]($it * $f) + 1
        if ($it -gt 40000000000L) { return $it }
    }
}

function Medir-Frequencia([double]$alvoMs = 250) {
    $it = Calibrar $alvoMs
    $s  = Cronometrar { [CpuLab]::AddChain($it, 1) }
    return @{ GHz = ($it * 8.0) / $s / 1e9; Iters = $it; Segundos = $s }
}

function Frequencia-Estavel {
    Aquecer-JIT
    Aquecer-Turbo 400
    $v = @( (Medir-Frequencia 250).GHz, (Medir-Frequencia 250).GHz, (Medir-Frequencia 250).GHz )
    return ($v | Sort-Object)[1]     # mediana
}

# =====================================================================
# 3. Informacoes do sistema, tudo por caminhos sem privilegio
# =====================================================================
function Teste-Info {
    Titulo '1. INFORMACOES DA MAQUINA'

    $ehAdmin = 'n/d'
    try {
        $ehAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Write-Host "  Sessao com privilegio de admin : $ehAdmin"
    Write-Host "  Versao do PowerShell           : $($PSVersionTable.PSVersion)"
    Write-Host "  Nucleos logicos (.NET)         : $([Environment]::ProcessorCount)"
    Write-Host "  Stopwatch de alta resolucao    : $([System.Diagnostics.Stopwatch]::IsHighResolution)"
    Write-Host "  Frequencia do Stopwatch (QPC)  : $([System.Diagnostics.Stopwatch]::Frequency) Hz"

    if (-not $script:PodeCim) {
        Nota 'WMI/CIM indisponivel nesta plataforma. Pulando a leitura de'
        Nota 'Win32_Processor e Win32_CacheMemory (so afeta o item 1).'
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host '  -- Win32_Processor (leitura liberada para usuario comum) --'
    # Get-CimInstance usa WMI local. Win32_Processor e legivel sem admin.
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($cpu) {
        Write-Host "  Modelo                : $($cpu.Name.Trim())"
        Write-Host "  Nucleos fisicos       : $($cpu.NumberOfCores)"
        Write-Host "  Nucleos logicos       : $($cpu.NumberOfLogicalProcessors)"
        Write-Host "  MaxClockSpeed         : $($cpu.MaxClockSpeed) MHz  <- frequencia NOMINAL"
        Write-Host "  CurrentClockSpeed     : $($cpu.CurrentClockSpeed) MHz <- costuma repetir a nominal"
        Write-Host "  L2 / L3               : $($cpu.L2CacheSize) KB / $($cpu.L3CacheSize) KB"
        Nota 'CurrentClockSpeed do WMI NAO e a frequencia real instantanea.'
        Nota 'Ela e derivada da nominal e quase sempre engana. Nao use.'
    } else {
        Nota 'Win32_Processor indisponivel nesta maquina.'
    }

    Write-Host ''
    Write-Host '  -- Caches declarados (Win32_CacheMemory) --'
    Get-CimInstance -ClassName Win32_CacheMemory -ErrorAction SilentlyContinue |
        Select-Object Purpose, @{n='KB';e={$_.MaxCacheSize}}, Level |
        Format-Table -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
    Write-Host ''
}

# Frequencia real pelo contador do Windows.
# Frequencia_real = MaxClockSpeed * PercentProcessorPerformance / 100
function Frequencia-Windows {
    if (-not $script:PodeCim) { return $null }
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cpu) { return $null }
    # A classe CIM abaixo tem nome em ingles em qualquer idioma do Windows.
    # Ja o Get-Counter usa nomes TRADUZIDOS ('% de Desempenho do Processador'
    # em portugues), o que quebra scripts. Por isso preferimos o CIM.
    # Em maquinas com varios grupos de processadores a instancia vem como
    # '0,_Total'. Filtramos no cliente para pegar os dois formatos.
    $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation `
                -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '_Total' -or $_.Name -like '*,_Total' } |
            Select-Object -First 1
    if (-not $perf -or $null -eq $perf.PercentProcessorPerformance) { return $null }
    return @{
        NominalMHz = $cpu.MaxClockSpeed
        Percentual = $perf.PercentProcessorPerformance
        RealGHz    = ($cpu.MaxClockSpeed * $perf.PercentProcessorPerformance / 100.0) / 1000.0
    }
}

function Teste-Freq {
    Titulo '2. FREQUENCIA REAL DO NUCLEO'
    Write-Host '  Metodo: cadeia de somas dependentes. Cada soma custa 1 ciclo,'
    Write-Host '  entao frequencia = numero de somas dividido pelo tempo.'
    Write-Host ''
    Aquecer-JIT
    Aquecer-Turbo 400
    $a = (Medir-Frequencia 250).GHz
    $b = (Medir-Frequencia 250).GHz
    $c = (Medir-Frequencia 250).GHz
    $med = ($a + $b + $c) / 3.0
    Write-Host ('  amostra 1            : {0,6:N3} GHz' -f $a)
    Write-Host ('  amostra 2            : {0,6:N3} GHz' -f $b)
    Write-Host ('  amostra 3            : {0,6:N3} GHz' -f $c)
    Linha
    Write-Host ('  FREQUENCIA EFETIVA   : {0,6:N3} GHz' -f $med) -ForegroundColor Green

    $w = Frequencia-Windows
    if ($w) {
        Write-Host ''
        Write-Host '  -- Conferindo com o proprio Windows --'
        Write-Host ('  Frequencia nominal            : {0:N0} MHz' -f $w.NominalMHz)
        Write-Host ('  % Processor Performance       : {0}%' -f $w.Percentual)
        Write-Host ('  Frequencia real segundo o SO  : {0:N3} GHz' -f $w.RealGHz)
        $erro = [Math]::Abs($med - $w.RealGHz) / $w.RealGHz * 100
        Write-Host ('  Diferenca entre os dois metodos: {0:N1}%' -f $erro)
        if ($erro -lt 12) { Bom 'Os dois metodos concordam. Medicao confiavel.' }
        else { Nota 'Divergencia alta. Feche outros programas e repita.' }
    } else {
        Nota 'Contador de desempenho indisponivel para este usuario.'
        Nota 'Peca ao administrador para incluir sua conta no grupo local'
        Nota '"Performance Monitor Users", ou siga so com o metodo por software.'
    }
    if ($med -gt 7.0) {
        Nota 'Valor implausivel: o JIT quebrou a cadeia de dependencia.'
        Nota 'Rode -Teste calib para diagnosticar.'
    }
    Write-Host ''
    return $med
}

function Teste-Calib([double]$ghz) {
    Titulo '3. CALIBRACAO: O INSTRUMENTO E CONFIAVEL?'
    Write-Host ('  Assumimos 1 ciclo por soma e chegamos a {0:N3} GHz.' -f $ghz)
    Write-Host '  Agora medimos operacoes de latencia CONHECIDA. Se baterem,'
    Write-Host '  a premissa se sustenta.'
    Write-Host ''
    Aquecer-JIT
    $it = Calibrar 200

    $sAdd = Cronometrar { [CpuLab]::AddChain($it, 1) }
    $sMul = Cronometrar { [CpuLab]::MulChain($it, 3) }
    $sDiv = Cronometrar { [CpuLab]::DivChain([long]($it / 4) + 1) }

    $cAdd = $sAdd * $ghz * 1e9 / ($it * 8.0)
    $cMul = $sMul * $ghz * 1e9 / ($it * 8.0)
    $cDiv = $sDiv * $ghz * 1e9 / ((([long]($it / 4) + 1)) * 8.0)

    Write-Host '  operacao              | medido | esperado | veredito'
    Linha
    $okA = ($cAdd -ge 0.85 -and $cAdd -le 1.20)
    $okM = ($cMul -ge 2.5  -and $cMul -le 4.5)
    $okD = ($cDiv -ge 10.0 -and $cDiv -le 26.0)
    Write-Host ('  {0,-21} | {1,6:N2} | {2,8} | {3}' -f 'soma  (ulong)',   $cAdd, '1',     $(if($okA){'OK'}else{'FORA DA FAIXA'}))
    Write-Host ('  {0,-21} | {1,6:N2} | {2,8} | {3}' -f 'mult  (ulong)',   $cMul, '3',     $(if($okM){'OK'}else{'FORA DA FAIXA'}))
    Write-Host ('  {0,-21} | {1,6:N2} | {2,8} | {3}' -f 'div   (double)',  $cDiv, '13-20', $(if($okD){'OK'}else{'FORA DA FAIXA'}))
    Linha
    if ($okA -and $okM -and $okD) {
        Bom 'Medicao valida.'
    } else {
        Nota 'Feche navegadores e antivirus em varredura, e repita.'
        $arch = ''
        try { $arch = "$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)" } catch { }
        if ($arch -match 'Arm' -or $env:PROCESSOR_ARCHITECTURE -match 'ARM') {
            Nota 'Arquitetura ARM detectada. O JIT ARM64 costuma medir a cadeia'
            Nota 'alto demais. Nesta maquina prefira o bench em C: src/bench.c'
        }
    }
    Write-Host ''
}

function Teste-ILP([double]$ghz) {
    Titulo '4. ILP: MESMAS INSTRUCOES, CPI DIFERENTE'
    Write-Host '  8 somas por iteracao, em 1 cadeia ou em 4 cadeias independentes.'
    Write-Host ''
    Aquecer-JIT
    $it = Calibrar 250
    $s1 = Cronometrar { [CpuLab]::AddChain($it, 1) }
    $s4 = Cronometrar { [CpuLab]::AddChain4($it, 1) }
    $c1 = $s1 * $ghz * 1e9 / ($it * 8.0)
    $c4 = $s4 * $ghz * 1e9 / ($it * 8.0)
    Write-Host '  cadeias | CPI (ciclos/soma) | IPC (somas/ciclo)'
    Linha
    Write-Host ('  {0,7} | {1,17:N3} | {2,17:N2}' -f '1', $c1, (1/$c1))
    Write-Host ('  {0,7} | {1,17:N3} | {2,17:N2}' -f '4', $c4, (1/$c4))
    Linha
    Write-Host '  Mesmo numero de instrucoes, mesmo processador, mesma frequencia.'
    Write-Host '  O que mudou foi so a DEPENDENCIA entre elas. O CPI e consequencia'
    Write-Host '  disso, nao uma propriedade fixa da instrucao.'
    Write-Host ''
}

function Teste-Lat([double]$ghz) {
    Titulo '5. LATENCIA POR TIPO DE INSTRUCAO'
    Write-Host '  Cadeia dependente: o tempo medido e a latencia pura da operacao.'
    Write-Host '  Observacao: no .NET a divisao inteira nao tem cadeia dedicada aqui;'
    Write-Host '  para inteiros comparamos soma (1) e multiplicacao (3).'
    Write-Host ''
    Aquecer-JIT
    $it  = Calibrar 200
    $itD = [long]($it / 4) + 1

    $sAdd  = Cronometrar { [CpuLab]::AddChain($it, 1) }
    $sMul  = Cronometrar { [CpuLab]::MulChain($it, 3) }
    $sFadd = Cronometrar { [CpuLab]::FaddChain($it, 0.0) }
    $sFmul = Cronometrar { [CpuLab]::FmulChain($it) }
    $sDiv  = Cronometrar { [CpuLab]::DivChain($itD) }

    $cAdd  = $sAdd  * $ghz * 1e9 / ($it  * 8.0)
    $cMul  = $sMul  * $ghz * 1e9 / ($it  * 8.0)
    $cFadd = $sFadd * $ghz * 1e9 / ($it  * 8.0)
    $cFmul = $sFmul * $ghz * 1e9 / ($it  * 8.0)
    $cDiv  = $sDiv  * $ghz * 1e9 / ($itD * 8.0)

    Write-Host '  operacao              | ciclos | referencia tipica'
    Linha
    Write-Host ('  {0,-21} | {1,6:N2} | {2}' -f 'add   (ulong)',  $cAdd,  '1')
    Write-Host ('  {0,-21} | {1,6:N2} | {2}' -f 'imul  (ulong)',  $cMul,  '3')
    Write-Host ('  {0,-21} | {1,6:N2} | {2}' -f 'addsd (double)', $cFadd, '2-4')
    Write-Host ('  {0,-21} | {1,6:N2} | {2}' -f 'mulsd (double)', $cFmul, '4-5')
    Write-Host ('  {0,-21} | {1,6:N2} | {2}' -f 'divsd (double)', $cDiv,  '13-20')
    Linha
    Write-Host '  O CPI medio de um programa real depende da MISTURA destas operacoes'
    Write-Host '  e, sobretudo, das dependencias entre elas.'
    Write-Host ''
}

function Teste-Mem([double]$ghz) {
    Titulo '6. LATENCIA DE MEMORIA (pointer chasing aleatorio)'
    Write-Host '  Cada acesso depende do anterior, entao o prefetcher nao ajuda.'
    Write-Host '  Observacao: o .NET adiciona verificacao de limite de array, o que'
    Write-Host '  soma cerca de 1 ciclo por acesso. Os degraus continuam visiveis.'
    Write-Host ''
    Write-Host '  working set |  ciclos/acesso |  ns/acesso | nivel provavel'
    Linha
    $tamanhos = @(8KB,16KB,32KB,64KB,128KB,256KB,512KB,1MB,2MB,4MB,8MB,16MB,32MB,64MB)
    foreach ($t in $tamanhos) {
        $arr = [CpuLab]::MontaCiclo([int]$t, 7)
        [CpuLab]::Chase($arr, 100000) | Out-Null            # aquece
        $passos = if ($t -lt 1MB) { 10000000L } else { 2000000L }
        $s = Cronometrar { [CpuLab]::Chase($arr, $passos) }
        $ns  = $s * 1e9 / $passos
        $cic = $ns * $ghz
        $niv = if ($cic -lt 9) { 'L1' } elseif ($cic -lt 28) { 'L2' } elseif ($cic -lt 85) { 'L3' } else { 'RAM' }
        $rot = if ($t -ge 1MB) { "$([int]($t/1MB)) MiB" } else { "$([int]($t/1KB)) KiB" }
        Write-Host ('  {0,11} | {1,14:N1} | {2,10:N2} | {3}' -f $rot, $cic, $ns, $niv)
        $arr = $null
        if ($t -ge 8MB) { [GC]::Collect() }
    }
    [GC]::Collect()
    Linha
    Write-Host '  Os degraus sao as fronteiras dos caches. Compare com a saida de'
    Write-Host '  Win32_CacheMemory mostrada no item 1.'
    Write-Host ''
}

function Teste-Matriz([double]$ghz, [int]$N = 2048) {
    Titulo "7. MATRIZ: POR LINHA x POR COLUNA (N = $N)"
    $mb = [Math]::Round(([double]$N * $N * 8) / 1MB, 1)
    Write-Host "  memoria da matriz    : $mb MiB"
    Write-Host ''
    $m = [CpuLab]::NovaMatriz($N)
    [CpuLab]::PorLinha($m, 256)  | Out-Null      # aquece o JIT
    [CpuLab]::PorColuna($m, 256) | Out-Null

    $sl = Cronometrar { [CpuLab]::PorLinha($m, $N) }
    $sc = Cronometrar { [CpuLab]::PorColuna($m, $N) }
    $el = [double]$N * $N

    Write-Host '  percurso    |  tempo (s) | ciclos/elemento'
    Linha
    Write-Host ('  {0,-11} | {1,10:N4} | {2,14:N2}' -f 'por linha',  $sl, ($sl*$ghz*1e9/$el))
    Write-Host ('  {0,-11} | {1,10:N4} | {2,14:N2}' -f 'por coluna', $sc, ($sc*$ghz*1e9/$el))
    Linha
    Write-Host ('  Razao coluna/linha   : {0:N2}x' -f ($sc/$sl)) -ForegroundColor Green
    Write-Host ''
    Write-Host '  O laco e o mesmo, so a ordem de percurso mudou. A diferenca de'
    Write-Host '  tempo e diferenca de CPI, e o CPI extra veio da memoria.'
    Write-Host ''
    $m = $null; [GC]::Collect()
}

function Teste-Ladder([int]$seg, [string]$arquivo) {
    Titulo "8. FREQUENCIA AO LONGO DO TEMPO ($seg s)"
    Write-Host '  Carga continua. Se houver limite termico ou de energia, a'
    Write-Host '  frequencia cai depois dos primeiros segundos.'
    Write-Host ''
    Aquecer-JIT
    # CSV sempre com ponto decimal e virgula separadora, independente do
    # idioma do Windows. Sem isso, em pt-BR o numero '1,5' colidiria com o
    # separador de campo e o arquivo abriria torto no Excel.
    function Num($v, $casas) {
        if ($null -eq $v -or "$v" -eq '') { return '' }
        return ([double]$v).ToString("F$casas", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $linhas = New-Object System.Collections.Generic.List[string]
    $linhas.Add('segundos,ghz_medido,ghz_windows,percentual')
    $rel = $SW::StartNew()
    while ($rel.Elapsed.TotalSeconds -lt $seg) {
        $t = [Math]::Round($rel.Elapsed.TotalSeconds, 2)
        $f = (Medir-Frequencia 200).GHz
        $w = Frequencia-Windows
        $wg = if ($w) { $w.RealGHz } else { '' }
        $wp = if ($w) { $w.Percentual } else { '' }
        $linhas.Add(('{0},{1},{2},{3}' -f (Num $t 2), (Num $f 4), (Num $wg 3), (Num $wp 0)))
        Write-Host ('  t={0,6:N1}s   medido={1,6:N3} GHz   windows={2} GHz' -f $t, $f, `
            $(if ($w) { '{0:N3}' -f $w.RealGHz } else { 'n/d' }))
    }
    $rel.Stop()
    if ($arquivo) {
        $linhas | Set-Content -Path $arquivo -Encoding UTF8
        Bom "CSV salvo em $arquivo"
        Write-Host '  Abra no Excel e faca um grafico de linha de ghz_medido por segundos.'
    }
    Write-Host ''
}

# =====================================================================
# 4. Execucao
# =====================================================================
Titulo 'LABORATORIO DE MEDICAO DE CPU  -  Windows, sem admin'
Preparar-Processo

if ($Teste -in @('tudo','ladder') -and -not (Test-Path $Saida)) {
    New-Item -ItemType Directory -Path $Saida -Force | Out-Null
}

switch ($Teste) {
    'info'   { Teste-Info }
    'freq'   { $null = Teste-Freq }
    'calib'  { Teste-Calib  (Frequencia-Estavel) }
    'ilp'    { Teste-ILP    (Frequencia-Estavel) }
    'lat'    { Teste-Lat    (Frequencia-Estavel) }
    'mem'    { Teste-Mem    (Frequencia-Estavel) }
    'matriz' { Teste-Matriz (Frequencia-Estavel) 2048 }
    'ladder' { Teste-Ladder $Segundos (Join-Path $Saida 'turbo-windows.csv') }
    'tudo'   {
        Teste-Info
        $ghz = Teste-Freq
        Teste-Calib  $ghz
        Teste-ILP    $ghz
        Teste-Lat    $ghz
        Teste-Mem    $ghz
        Teste-Matriz $ghz 2048
        Teste-Ladder ([Math]::Min($Segundos,60)) (Join-Path $Saida 'turbo-windows.csv')
        Titulo 'FIM'
        Bom "Resultados em: $((Resolve-Path $Saida).Path)"
    }
    default  {
        Nota "Teste '$Teste' desconhecido."
        Nota "Use: info | freq | calib | ilp | lat | mem | matriz | ladder | tudo"
    }
}
