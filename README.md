# lab-cpi

Laboratório prático de medição de CPU para Infraestrutura de Hardware.
Mede **frequência real, CPI, IPC, latência de instrução e latência de cache**
sem PMU, sem root e sem administrador. Funciona em WSL2, onde o `perf` não
consegue ler contadores de hardware.

Continuação do experimento da matriz (Aula 01) e do slide "Experimento:
medindo CPI de verdade".

## Início rápido

### Linux ou WSL2

```bash
sudo apt update
sudo apt install -y build-essential linux-tools-common linux-tools-generic time
cd src && make && cd ../linux
./medir.sh
```

Resultados em `linux/resultados/`.

### Windows, sem administrador

```powershell
cd windows
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Medir-CPU.ps1
```

### Gerar o .exe a partir do WSL

```bash
sudo apt install -y gcc-mingw-w64-x86-64
cd src && make win
```

## O que cada coisa mede

| Comando | Mede |
|---|---|
| `./bench info` | CPU, relógios, caches declarados |
| `./bench freq` | Frequência real do núcleo sob carga |
| `./bench calib` | Valida o método contra latências conhecidas |
| `./bench ilp` | CPI e IPC com 1, 2, 4 e 8 cadeias independentes |
| `./bench lat` | Latência em ciclos por tipo de instrução |
| `./bench mem` | Latência por nível de cache, de 8 KiB a 128 MiB |
| `./bench matriz 2048` | Percurso por linha versus por coluna |
| `./bench ladder 90` | Frequência ao longo do tempo, em CSV |
| `./bench all` | Bateria completa |

## Como funciona

Uma cadeia de somas inteiras **dependentes** custa exatamente 1 ciclo por
soma. Logo `frequência = número_de_somas / tempo`. Com a frequência real em
mãos, qualquer tempo medido vira ciclos, e qualquer contagem de instruções
vira CPI.

O subcomando `calib` valida a premissa medindo `imul` (3 ciclos) e `divsd`
(13 a 20 ciclos). Se esses valores baterem, a régua está correta.

## Arquivos

```
00-ROTEIRO-PROFESSOR.md   teoria, roteiro minuto a minuto, dicionário de flags,
                          gabarito, rubrica de avaliação
01-ROTEIRO-ALUNO.md       folha de laboratório para distribuir
src/bench.c               motor de medição em C, x86-64 e ARM64
src/Makefile              all, win, asm, matriz-asm, clean
linux/medir.sh            driver com detecção de perf e diagnóstico de WSL
windows/Medir-CPU.ps1     versão PowerShell, motor em C# compilado por Add-Type
```

## Licença

Material didático. Uso livre para fins educacionais, com atribuição.
Maciel, Ronierison. CESAR School.
