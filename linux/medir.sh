#!/usr/bin/env bash
# =====================================================================
# medir.sh  -  Driver do cperf para Linux e WSL2 (com diagnostico de perf)
# Infraestrutura de Hardware / CESAR School
#
#   ./medir.sh            roda tudo e gera resultados/
#   ./medir.sh diag       so o diagnostico de ambiente
#   ./medir.sh perf       so a parte de perf (PMU real, quando existe)
#   ./medir.sh cperf      so o cperf (cronometragem calibrada, sempre funciona)
#
# Nao precisa de root. Onde algo exigir privilegio, o script avisa e segue.
# =====================================================================

set -uo pipefail

CPERF="${CPERF:-../src/cperf}"
OUT="${OUT:-resultados}"
CPU_ALVO="${CPU_ALVO:-1}"     # nucleo onde fixamos as medidas
LADDER_SEG="${LADDER_SEG:-60}" # duracao da amostragem de turbo, em segundos
PERF=""                        # preenchido por detectar_perf()

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
amar()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
titulo(){ echo; azul "=============================================================="; \
          azul " $*"; azul "=============================================================="; }

mkdir -p "$OUT"

# ---------------------------------------------------------------------
# 1. Diagnostico de ambiente
# ---------------------------------------------------------------------
detectar_perf() {
  # No WSL2 o pacote linux-tools-generic instala um perf com versao diferente
  # da do kernel da Microsoft, entao o wrapper /usr/bin/perf recusa rodar.
  # O binario real fica em /usr/lib/linux-tools/<versao>/perf e funciona.
  if command -v perf >/dev/null 2>&1 && perf --version >/dev/null 2>&1; then
    PERF="perf"; return 0
  fi
  local cand
  cand=$(ls -1 /usr/lib/linux-tools/*/perf 2>/dev/null | tail -n1 || true)
  if [ -n "$cand" ] && "$cand" --version >/dev/null 2>&1; then
    PERF="$cand"; return 0
  fi
  PERF=""; return 1
}

diag() {
  titulo "1. AMBIENTE"

  local wsl="nao"
  grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null && wsl="SIM"
  echo "  WSL detectado        : $wsl"
  echo "  Kernel               : $(uname -r)"
  echo "  Arquitetura          : $(uname -m)"

  echo
  echo "-- lscpu (resumo) --"
  # -e nao serve aqui; queremos o formato longo filtrado
  lscpu 2>/dev/null | grep -Ei \
    'Model name|Architecture|^CPU\(s\)|Thread|Core\(s\)|Socket|MHz|BogoMIPS|Virtual|Hypervisor|cache' \
    | grep -vi 'flags' | sed 's/^/  /'

  echo
  echo "-- Caches declarados pelo sistema --"
  # getconf funciona no WSL, ao contrario de /sys/devices/system/cpu/cpufreq
  getconf -a 2>/dev/null | grep -i cache | grep -v ' 0$' | sed 's/^/  /' || true

  echo
  echo "-- Governor e frequencia via sysfs --"
  if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for f in scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq; do
      [ -r "/sys/devices/system/cpu/cpu0/cpufreq/$f" ] && \
        echo "  $f = $(cat /sys/devices/system/cpu/cpu0/cpufreq/$f)"
    done
  else
    amar "  sysfs cpufreq indisponivel."
    amar "  No WSL2 isso e esperado: o kernel roda dentro de uma VM Hyper-V e"
    amar "  nao enxerga o driver de frequencia do hardware real."
  fi

  echo
  echo "-- 'cpu MHz' do /proc/cpuinfo --"
  grep -i 'cpu MHz' /proc/cpuinfo 2>/dev/null | head -4 | sed 's/^/  /' || \
    amar "  ausente (normal no WSL2)"

  titulo "2. O PMU ESTA DISPONIVEL?"
  echo "  perf_event_paranoid  : $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 'ausente')"
  echo "    -1 = tudo liberado | 0 = eventos de CPU | 1 = so do proprio processo"
  echo "     2 = padrao, so user-space | 3 = perf desabilitado"
  echo

  if detectar_perf; then
    verde "  perf encontrado: $PERF"
    echo
    echo "-- teste de contadores de hardware --"
    if "$PERF" stat -e cycles,instructions true 2>&1 | grep -qiE 'not supported|not counted|<not'; then
      amar "  Contadores de HARDWARE INDISPONIVEIS."
      amar "  Causa tipica: WSL2 ou VM. O hipervisor nao expoe o PMU ao convidado."
      amar "  Consequencia: 'perf stat -e cycles,instructions' nao funciona."
      amar "  Solucao do laboratorio: medir ciclos por CRONOMETRAGEM CALIBRADA."
      echo "  (e o que o cperf faz)"
      export PMU_OK=0
    else
      verde "  Contadores de hardware FUNCIONANDO. Voce tem PMU real."
      export PMU_OK=1
    fi
  else
    amar "  perf nao encontrado ou incompativel com este kernel."
    echo
    echo "  Para instalar no Ubuntu/WSL:"
    echo "    sudo apt update && sudo apt install linux-tools-common linux-tools-generic"
    echo "    ls /usr/lib/linux-tools/            # veja a versao instalada"
    echo "    /usr/lib/linux-tools/<versao>/perf --version"
    echo
    echo "  No WSL2 o wrapper reclama de versao do kernel. Chame o binario direto,"
    echo "  ou compile o perf do proprio kernel da Microsoft:"
    echo "    git clone --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel"
    echo "    cd WSL2-Linux-Kernel/tools/perf && make -j\$(nproc)"
    export PMU_OK=0
  fi
}

# ---------------------------------------------------------------------
# 2. Medicoes com perf (quando ha PMU)
# ---------------------------------------------------------------------
rodar_perf() {
  titulo "3. MEDICAO COM perf"
  detectar_perf || { amar "  perf indisponivel, pulando esta secao."; return; }

  local alvo="${1:-$CPERF}"
  [ -x "$alvo" ] || { amar "  binario $alvo nao encontrado. Rode 'make' em ../src"; return; }

  echo "-- 3.1 Contagem basica: ciclos, instrucoes e IPC --"
  echo "   flags: -e lista de eventos | -r 3 repete 3 vezes e mostra desvio"
  "$PERF" stat -r 3 -e cycles,instructions,task-clock,page-faults \
      taskset -c "$CPU_ALVO" "$alvo" matriz 1024 2>&1 | tail -25 | sed 's/^/   /'

  echo
  echo "-- 3.2 Detalhado: acrescenta eventos de cache --"
  echo "   flags: -d adiciona L1 e LLC | -dd e -ddd adicionam mais niveis"
  "$PERF" stat -d taskset -c "$CPU_ALVO" "$alvo" matriz 1024 2>&1 | tail -25 | sed 's/^/   /'

  echo
  echo "-- 3.3 Razao de turbo pelo par cycles / ref-cycles --"
  echo "   cycles conta ciclos REAIS do nucleo"
  echo "   ref-cycles conta na frequencia NOMINAL fixa"
  echo "   a razao entre os dois e exatamente o multiplicador de turbo"
  "$PERF" stat -e cycles,ref-cycles taskset -c "$CPU_ALVO" "$alvo" freq 2>&1 \
      | tail -12 | sed 's/^/   /'

  echo
  echo "-- 3.4 Saida em CSV para planilha --"
  echo "   flags: -x, usa virgula como separador"
  "$PERF" stat -x, -e cycles,instructions,cache-misses,branch-misses \
      taskset -c "$CPU_ALVO" "$alvo" matriz 1024 2> "$OUT/perf-matriz.csv"
  sed 's/^/   /' "$OUT/perf-matriz.csv" 2>/dev/null | head
  verde "   salvo em $OUT/perf-matriz.csv"
}

# ---------------------------------------------------------------------
# 3. cperf (funciona com ou sem PMU)
# ---------------------------------------------------------------------
rodar_cperf() {
  titulo "4. MEDICAO SEM PMU (funciona no WSL)"
  [ -x "$CPERF" ] || { amar "  Compile primeiro: cd ../src && make"; return 1; }

  # taskset -c N fixa o processo no nucleo N. Reduz muito a variancia,
  # porque o escalonador para de migrar o processo entre nucleos.
  local RUN=(taskset -c "$CPU_ALVO" "$CPERF")
  command -v taskset >/dev/null 2>&1 || RUN=("$CPERF")

  # nice -n -5 exigiria privilegio; nice positivo nao ajuda. Ficamos no padrao.
  "${RUN[@]}" info   | tee "$OUT/01-info.txt"
  "${RUN[@]}" freq   | tee "$OUT/02-freq.txt"
  "${RUN[@]}" calib  | tee "$OUT/03-calib.txt"
  "${RUN[@]}" ilp    | tee "$OUT/04-ilp.txt"
  "${RUN[@]}" lat    | tee "$OUT/05-lat.txt"
  "${RUN[@]}" mem    | tee "$OUT/06-mem.txt"
  "${RUN[@]}" matriz 2048 | tee "$OUT/07-matriz.txt"

  titulo "5. TURBO AO LONGO DO TEMPO"
  echo "  Gerando ${LADDER_SEG} s de amostras. Observe se a frequencia cai."
  "${RUN[@]}" ladder "$LADDER_SEG" > "$OUT/08-turbo.csv"
  verde "  salvo em $OUT/08-turbo.csv"
  echo
  echo "  Primeiras e ultimas amostras:"
  head -4 "$OUT/08-turbo.csv" | sed 's/^/    /'
  echo "    ..."
  tail -3 "$OUT/08-turbo.csv" | sed 's/^/    /'
  echo
  echo "  Para plotar:"
  echo "    gnuplot -e \"set datafile separator ','; set term dumb; \\"
  echo "      plot '$OUT/08-turbo.csv' every ::1 using 1:2 with lines\""
}

# ---------------------------------------------------------------------
# 4. Extras
# ---------------------------------------------------------------------
extras() {
  titulo "6. EXTRAS"

  echo "-- /usr/bin/time -v: visao do sistema operacional --"
  echo "   mostra tempo de usuario x de kernel, RSS maximo, trocas de contexto"
  if [ -x /usr/bin/time ] && [ -x "$CPERF" ]; then
    /usr/bin/time -v "$CPERF" matriz 1024 2>&1 | grep -Ei \
      'User time|System time|Elapsed|Maximum resident|context switch|Page faults' \
      | sed 's/^/   /'
  else
    amar "   /usr/bin/time nao instalado (sudo apt install time)"
  fi

  echo
  echo "-- Prova de que a diferenca da matriz e CPI, e nao contagem de instrucao --"
  if command -v objdump >/dev/null 2>&1 && [ -x "$CPERF" ]; then
    for fn in soma_por_linha soma_por_coluna; do
      n=$(objdump -d "$CPERF" \
          | awk "/<$fn>:/,/^\$/" \
          | grep -P '^\s+[0-9a-f]+:\t' \
          | grep -vE '\b(nop|nopl|nopw|data16|cs nop|xchg\s+%ax,%ax)\b' \
          | wc -l)
      printf "     %-16s : %s instrucoes na funcao inteira\n" "$fn" "$n"
    done
    echo
    echo "   Laco interno de cada versao (compile com -fno-unroll-loops):"
    echo "   --- por linha ---"
    objdump -d "$CPERF" | awk '/<soma_por_linha>:/,/^$/' \
      | grep -E 'addsd|add |cmp|jne' | head -6 | sed 's/^/     /'
    echo "   --- por coluna ---"
    objdump -d "$CPERF" | awk '/<soma_por_coluna>:/,/^$/' \
      | grep -E 'addsd|add |cmp|jne' | head -6 | sed 's/^/     /'
    echo
    echo "   Sao 4 e 5 instrucoes por elemento: cerca de 25% de diferenca em IC."
    echo "   O tempo, porem, difere de 4x a 10x. Logo a diferenca e CPI."
  fi
}

# ---------------------------------------------------------------------
main() {
  case "${1:-tudo}" in
    diag)   diag ;;
    perf)   rodar_perf "${2:-$CPERF}" ;;
    cperf)  rodar_cperf ;;
    extras) extras ;;
    tudo)   diag; rodar_perf; rodar_cperf; extras
            titulo "FIM"
            verde "Resultados em: $(cd "$OUT" && pwd)" ;;
    *) echo "uso: $0 [diag|perf|cperf|extras|tudo]"; exit 1 ;;
  esac
}
main "$@"
