#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "=== Quasar line counts (.sv / .svh) ==="
echo
printf "%-40s %8s\n" "path" "lines"
printf "%-40s %8s\n" "----------------------------------------" "--------"

sum=0
while IFS= read -r f; do
  n=$(wc -l < "$f")
  printf "%-40s %8d\n" "$f" "$n"
  sum=$((sum + n))
done < <(find rtl tb assert model -type f \( -name '*.sv' -o -name '*.svh' \) | sort)

echo
printf "%-40s %8d\n" "TOTAL .sv/.svh" "$sum"
echo
echo "=== By tree ==="
for d in rtl/pkg rtl/infra rtl/book rtl/match rtl/risk rtl/ingress rtl/egress rtl/csr rtl/soc tb/common tb/smoke tb/uvm_lite assert model; do
  if [ -d "$d" ]; then
    n=$(find "$d" -type f \( -name '*.sv' -o -name '*.svh' \) -print0 | xargs -0 wc -l 2>/dev/null | tail -1 | awk '{print $1}')
    printf "%-40s %8s\n" "$d" "${n:-0}"
  fi
done
echo
echo "C++ golden: $(wc -l < model/golden_book.cpp) + $(wc -l < model/golden_book.hpp) + $(wc -l < model/quasar_dpi.cpp)"
