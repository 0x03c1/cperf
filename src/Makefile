# =====================================================================
# Laboratorio: medindo CPU de verdade
# Infraestrutura de Hardware / CESAR School
#
#   make            compila ./bench para Linux/WSL
#   make win        compila ./bench.exe para Windows (precisa de mingw-w64)
#   make asm        gera bench.s para inspecionar o assembly gerado
#   make matriz-asm mostra o laco interno das duas versoes da matriz
#   make clean
#
# Instalar o cross-compiler no WSL:
#   sudo apt install gcc-mingw-w64-x86-64
# =====================================================================

CC      = gcc
WINCC   = x86_64-w64-mingw32-gcc

# -O2                  otimiza, mas sem trocar a estrutura dos lacos
# -fno-tree-vectorize  desliga SIMD automatico: mantem 1 elemento por
#                      iteracao e torna a contagem de instrucoes previsivel
# -fno-omit-frame-pointer  deixa a pilha legivel para perf record -g
# -fno-unroll-loops    impede o GCC de desenrolar os lacos da matriz, o que
#                      deixaria as duas versoes com contagens de instrucao
#                      muito diferentes e estragaria a comparacao de CPI
CFLAGS  = -O2 -fno-tree-vectorize -fno-unroll-loops \
          -fno-omit-frame-pointer -Wall -Wextra
LDFLAGS = -lm

all: bench

bench: bench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

win: bench.c
	$(WINCC) -O2 -fno-tree-vectorize -Wall -o bench.exe bench.c
	@echo "bench.exe pronto. Copie para o Windows e rode no PowerShell."

# Gera o assembly para o aluno conferir o laco interno com os proprios olhos.
asm: bench.c
	$(CC) $(CFLAGS) -S -o bench.s bench.c
	@echo "Veja bench.s"

# Mostra o laco interno das duas versoes da matriz lado a lado.
# Serve para provar que as duas executam as MESMAS instrucoes.
matriz-asm: bench
	@echo "=== soma_por_linha ==="
	@objdump -d bench | sed -n '/<soma_por_linha>:/,/ret/p'
	@echo ""
	@echo "=== soma_por_coluna ==="
	@objdump -d bench | sed -n '/<soma_por_coluna>:/,/ret/p'

clean:
	rm -f bench bench.exe bench.s *.o

.PHONY: all win asm matriz-asm clean
