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

### macOS

Não há `apt`, `perf` nem `taskset`; use o compilador do sistema e rode o
`bench` direto.

```bash
cd src
cc -O2 -fno-unroll-loops -o bench bench.c
./bench all
```

Em Apple Silicon o processo migra entre P-cores e E-cores, então `freq`
oscila mais que no Linux. Confie na mediana de `./bench freq` e valide com
`./bench calib`. O aviso "nao consegui fixar a afinidade" é esperado no
macOS e não impede a medição.

### Windows, sem administrador

Não precisa de compilador nem do `.exe`: o script traz o próprio motor de
medição em C# e o compila na hora com `Add-Type`.

```powershell
cd windows
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Medir-CPU.ps1
```

Funciona no Windows PowerShell 5.1 e no PowerShell 7.x. Resultados em
`windows\resultados\`. Para um teste isolado: `.\Medir-CPU.ps1 -Teste freq`.

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

No Windows o mesmo subcomando vai no parâmetro `-Teste`:
`.\Medir-CPU.ps1 -Teste mem`, `.\Medir-CPU.ps1 -Teste ladder -Segundos 90`,
`.\Medir-CPU.ps1` sozinho roda a bateria completa.

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
