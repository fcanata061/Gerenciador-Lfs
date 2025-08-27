#!/bin/sh
# lfs.sh — Builder/gerenciador POSIX para Linux From Scratch com receitas
# Requisitos sugeridos: POSIX sh, curl, git, tar, xz, bzip2, gzip, unzip, 7z (opcional), patch, fakeroot, find, awk, sed, sort, ldd, make, gcc, zstd (opcional)
# Nota: Este é um script-base completo e extensível. Ajuste caminhos/flags para seu ambiente.

# -----------------------------
# Configuração padrão
# -----------------------------
set -eu
umask 022

# Diretórios base (podem ser sobrescritos por env/flags)
: "${LFS:=/mnt/lfs}"
: "${REPO:=/srv/recipes}"            # Estrutura esperada: $REPO/{base,x11,extras,desktop}/<pkg>-<ver>/...recipe
: "${ROOTDIR:=/}"                    # Raiz do sistema alvo
: "${SYSDB:=/var/lib/lfsdb}"         # Banco de dados simples de pacotes
: "${PKGCACHE:=/var/cache/lfs-pkgs}" # Cache de pacotes gerados (.tar.*)
: "${LOGDIR:=/var/log/lfsbuild}"      # Logs por pacote
: "${HOOKSD:=/etc/lfs/hooks}"         # Hooks (ex.: post-remove.d)
: "${WORKDIR:=/var/tmp/lfs-work}"     # Diretório de trabalho/compilação
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${COLOR:=auto}"                    # auto|always|never
: "${FORCE:=0}"                       # 1 = forçar
: "${NOCLEAN:=0}"                     # 1 = manter workdirs
: "${QUIET:=0}"
: "${SPINNER:=1}"

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export LFS REPO ROOTDIR SYSDB PKGCACHE LOGDIR HOOKSD WORKDIR JOBS

# -----------------------------
# Cores/estética
# -----------------------------
supports_color() {
  [ "$COLOR" = always ] && return 0
  [ "$COLOR" = never ] && return 1
  [ -t 1 ] && [ -n "${TERM-}" ] && case "$TERM" in *color*|xterm*|screen*|vt100*) return 0;; esac
  return 1
}
if supports_color; then
  C0="\033[0m"; C1="\033[1;36m"; C2="\033[1;32m"; C3="\033[1;33m"; C4="\033[1;31m"; C5="\033[1;35m"
else
  C0=""; C1=""; C2=""; C3=""; C4=""; C5=""
fi

msg()  { [ "$QUIET" = 1 ] || printf "%s[+] %s%s\n" "$C2" "$*" "$C0"; }
info() { [ "$QUIET" = 1 ] || printf "%s[i] %s%s\n" "$C1" "$*" "$C0"; }
warn() { printf "%s[!] %s%s\n" "$C3" "$*" "$C0" 1>&2; }
err()  { printf "%s[x] %s%s\n" "$C4" "$*" "$C0" 1>&2; exit 1; }

_spinner_pid=""
start_spinner() {
  [ "$SPINNER" = 1 ] || return 0
  ( while :; do for c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do printf "\r%s" "$c"; sleep 0.08; done; done ) &
  _spinner_pid=$!
}
stop_spinner() {
  [ -n "$_spinner_pid" ] || return 0
  kill "$_spinner_pid" 2>/dev/null || true
  wait "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=""
  printf "\r"
}

# -----------------------------
# Utilidades
# -----------------------------
ensure_dirs() {
  umask 022
  for d in "$SYSDB/packages" "$SYSDB/files" "$PKGCACHE" "$LOGDIR" "$HOOKSD/post-remove.d" "$WORKDIR"; do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

log_file_for() { pkg="$1"; ver="$2"; echo "$LOGDIR/${pkg}-${ver}.log"; }

pkgdb_dir() { echo "$SYSDB/packages/$1"; }

is_installed() { pkg="$1"; [ -f "$(pkgdb_dir "$pkg")/version" ]; }

installed_version() { pkg="$1"; [ -f "$(pkgdb_dir "$pkg")/version" ] && cat "$(pkgdb_dir "$pkg")/version" || echo ""; }

record_install() {
  pkg="$1"; ver="$2"; listfile="$3"; meta_dir="$(pkgdb_dir "$pkg")"
  mkdir -p "$meta_dir"
  printf "%s\n" "$ver" >"$meta_dir/version"
  [ -f "$listfile" ] && cp "$listfile" "$SYSDB/files/${pkg}.list"
  date +%FT%T >"$meta_dir/installed_at"
}

remove_record() {
  pkg="$1"; rm -f "$(pkgdb_dir "$pkg")/version" "$SYSDB/files/${pkg}.list" "$(pkgdb_dir "$pkg")/installed_at" 2>/dev/null || true
}

# Detecta receita (toolchain ou normal)
find_recipe() {
  name="$1"; [ -n "${2-}" ] && ver="$2" || ver=""
  # Tenta localizar em $REPO/*/name-ver/name-ver*.recipe
  if [ -n "$ver" ]; then
    f=$(find "$REPO" -type f -path "*/${name}-${ver}/*" -name "${name}-${ver}*.recipe" | sort | head -n1)
  else
    f=$(find "$REPO" -type f -name "${name}-*.recipe" | sort | tail -n1)
  fi
  [ -n "$f" ] && printf "%s\n" "$f" || return 1
}

# Baixa arquivo/URL (curl) ou git
fetch_source() {
  url="$1"; outdir="$2"; mkdir -p "$outdir"; cd "$outdir"
  case "$url" in
    git+*) giturl=${url#git+}; git clone --depth=1 "$giturl" ;;
    *.git) git clone --depth=1 "$url" ;;
    *) curl -fL --retry 3 -O "$url" ;;
  esac
}

# Descompacta para workdir
extract_any() {
  archive="$1"; dest="$2"; mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz)    tar -xzf "$archive" -C "$dest" ;;
    *.tar.xz)          tar -xJf "$archive" -C "$dest" ;;
    *.tar.bz2|*.tbz2)  tar -xjf "$archive" -C "$dest" ;;
    *.tar.zst)         tar --zstd -xf "$archive" -C "$dest" ;;
    *.zip)             unzip -q "$archive" -d "$dest" ;;
    *.xz)              mkdir -p "$dest"; xz -dkc "$archive" >"$dest/$(basename "${archive%.xz}")" ;;
    *.gz)              mkdir -p "$dest"; gzip -dkc "$archive" >"$dest/$(basename "${archive%.gz}")" ;;
    *.bz2)             mkdir -p "$dest"; bzip2 -dkc "$archive" >"$dest/$(basename "${archive%.bz2}")" ;;
    *.7z)              7z x -o"$dest" "$archive" ;;
    *)                 err "Formato não suportado: $archive" ;;
  esac
}

apply_patches() {
  # Aplica patch(s) no diretório corrente
  for p in "$@"; do
    info "Aplicando patch $(basename "$p")"
    patch -p1 < "$p"
  done
}

# -----------------------------
# Parser de receita
# -----------------------------
# Formato esperado da receita (.recipe):
#   NAME=gcc
#   VERSION=12.1
#   URLS="https://.../gcc-12.1.tar.xz"
#   PATCHES="https://.../fix1.patch https://.../fix2.patch" (opcional)
#   DEPENDS="gmp mpfr mpc"
#   TOOLCHAIN=1 (opcional p/ toolchain)
#   CONFIGURE="./configure --prefix=/usr ..."
#   BUILD="make -j$JOBS"
#   INSTALL="make DESTDIR=\"$DESTDIR\" install"
#   POST_INSTALL="ldconfig || true" (opcional)
#   PKGFILES_GLOB="/usr/bin/gcc /usr/lib64/*.so* ..." (opcional)

load_recipe() {
  RECIPE_FILE="$1"; [ -f "$RECIPE_FILE" ] || err "Receita não encontrada: $RECIPE_FILE"
  # shellcheck disable=SC2034
  NAME="" VERSION="" URLS="" PATCHES="" DEPENDS="" TOOLCHAIN="" CONFIGURE="" BUILD="" INSTALL="" POST_INSTALL="" PKGFILES_GLOB=""
  # carrega variáveis da receita em subshell seguro
  # shellcheck source=/dev/null
  . "$RECIPE_FILE"
  [ -n "$NAME" ] || err "Receita inválida: NAME vazio"
  [ -n "$VERSION" ] || err "Receita inválida: VERSION vazio"
}

# -----------------------------
# Resolução de dependências
# -----------------------------
resolve_deps() {
  # Entrada: lista de pacotes (names). Saída: ordem topológica simples
  todo="$*"
  out=""
  seen=""
  visit() {
    n="$1"
    echo "$seen" | grep -q "(^| )$n( |$)" && return 0
    seen="$seen $n"
    rf=$(find_recipe "$n") || err "Receita de $n não encontrada"
    load_recipe "$rf"
    for d in $DEPENDS; do
      visit "$d"
    done
    echo "$out" | grep -q "(^| )$n( |$)" || out="$out $n"
  }
  for p in $todo; do visit "$p"; done
  printf "%s\n" "$out" | awk '{$1=$1}1'
}

# -----------------------------
# Build/instalação
# -----------------------------
build_one() {
  recipe="$1"; load_recipe "$recipe"
  pkg="$NAME"; ver="$VERSION"; logf=$(log_file_for "$pkg" "$ver")
  msg "Construindo $pkg-$ver"
  ensure_dirs
  mkdir -p "$WORKDIR/$pkg-$ver/sources" "$WORKDIR/$pkg-$ver/build" "$WORKDIR/$pkg-$ver/destdir"
  SOURCES="$WORKDIR/$pkg-$ver/sources"
  BUILDDIR="$WORKDIR/$pkg-$ver/build"
  DESTDIR="$WORKDIR/$pkg-$ver/destdir"

  # Baixar fontes
  for u in $URLS; do ( cd "$SOURCES"; fetch_source "$u" "$SOURCES" ); done

  # Baixar patches (se URLs)
  PATCHFILES=""
  for p in $PATCHES; do
    case "$p" in http*|git+*|*.git) ( cd "$SOURCES"; fetch_source "$p" "$SOURCES" );;
         *) : ;; # caminho local
    esac
  done
  # Coletar nomes de patches baixados ou locais
  for p in $PATCHES; do
    case "$p" in http*|git+*|*.git) for f in "$SOURCES"/*.patch "$SOURCES"/*.diff 2>/dev/null; do [ -f "$f" ] && PATCHFILES="$PATCHFILES $f"; done ;;
         *) [ -f "$p" ] && PATCHFILES="$PATCHFILES $p" ;;
    esac
  done

  # Extrair (assume primeiro tarball define root)
  srcroot="$BUILDDIR/src"
  rm -rf "$srcroot"; mkdir -p "$srcroot"
  first_archive=$(ls -1 "$SOURCES" 2>/dev/null | head -n1 || true)
  [ -n "$first_archive" ] || err "Nenhuma fonte encontrada para $pkg-$ver"
  extract_any "$SOURCES/$(basename "$first_archive")" "$srcroot"
  # Normaliza diretório raiz (assume um único diretório dentro)
  SRCDIR=$(find "$srcroot" -mindepth 1 -maxdepth 1 -type d | head -n1)
  [ -n "${SRCDIR-}" ] || SRCDIR="$srcroot"

  ( cd "$SRCDIR"
    # Aplicar patches
    [ -n "$PATCHFILES" ] && apply_patches $PATCHFILES
    # Configurar/compilar/instalar
    [ -n "$CONFIGURE" ] && sh -c "$CONFIGURE" 2>&1 | tee -a "$logf"
    [ -n "$BUILD" ] && start_spinner; { sh -c "$BUILD" 2>&1 | tee -a "$logf"; rc=$?; stop_spinner; exit $rc; }
    [ -n "$INSTALL" ] || INSTALL="make DESTDIR=\"$DESTDIR\" install"
    fakeroot sh -c "$INSTALL" 2>&1 | tee -a "$logf"
  )

  # Empacotar (tar.zst se disponível, senão tar.xz)
  pkgfile="$PKGCACHE/${pkg}-${ver}.tar"
  ( cd "$DESTDIR"; tar -cf "$pkgfile" . )
  if command -v zstd >/dev/null 2>&1; then
    zstd -f "$pkgfile"
    pkgfile="${pkgfile}.zst"
  else
    xz -f "$pkgfile"
    pkgfile="${pkgfile}.xz"
  fi

  # Instalar no sistema (destino ROOTDIR)
  info "Instalando $pkg-$ver em $ROOTDIR"
  fakeroot sh -c "tar -xf '$pkgfile' -C '$ROOTDIR'"

  # Registro de arquivos
  tmp_list="$WORKDIR/$pkg-$ver/filelist.txt"
  ( cd "$DESTDIR"; find . -mindepth 1 -type f -o -type l -o -type d | sed 's#^\.#/#' | sort ) > "$tmp_list"
  record_install "$pkg" "$ver" "$tmp_list"

  # Pós-instalação
  [ -n "$POST_INSTALL" ] && ( cd "$ROOTDIR"; sh -c "$POST_INSTALL" ) || true

  # Limpeza
  if [ "$NOCLEAN" = 0 ]; then rm -rf "$WORKDIR/$pkg-$ver"; fi
  msg "OK: $pkg-$ver"
}

install_with_deps() {
  names="$*"
  order=$(resolve_deps $names)
  for n in $order; do
    rf=$(find_recipe "$n")
    load_recipe "$rf"
    if is_installed "$NAME" && [ "$FORCE" = 0 ]; then
      info "$NAME já instalado (versão $(installed_version "$NAME")), use --force para reconstruir"
      continue
    fi
    build_one "$rf"
  done
}

# -----------------------------
# Remoção / rollback / hooks
# -----------------------------
run_post_remove_hooks() {
  pkg="$1"
  if [ -d "$HOOKSD/post-remove.d" ]; then
    for h in "$HOOKSD/post-remove.d"/*; do [ -x "$h" ] && "$h" "$pkg" || true; done
  fi
}

remove_pkg() {
  pkg="$1"
  is_installed "$pkg" || { warn "$pkg não está instalado"; return 0; }
  list="$SYSDB/files/${pkg}.list"
  [ -f "$list" ] || err "Lista de arquivos não encontrada para $pkg"
  info "Removendo arquivos de $pkg"
  # Remove em ordem inversa, evitando diretórios não vazios
  tac "$list" | while IFS= read -r path; do
    target="$ROOTDIR$path"
    if [ -L "$target" ] || [ -f "$target" ]; then rm -f "$target" 2>/dev/null || true; fi
    if [ -d "$target" ]; then rmdir "$target" 2>/dev/null || true; fi
  done
  remove_record "$pkg"
  run_post_remove_hooks "$pkg"
  msg "Removido: $pkg"
}

rollback_pkg() {
  pkg="$1"; ver="${2-}"
  # Restaura do cache do pacote, se existir
  [ -n "$ver" ] || ver=$(installed_version "$pkg")
  [ -n "$ver" ] || err "Sem versão conhecida para rollback de $pkg"
  for ext in zst xz; do
    f="$PKGCACHE/${pkg}-${ver}.tar.$ext"
    if [ -f "$f" ]; then
      info "Restaurando $pkg-$ver do cache"
      fakeroot sh -c "tar -xf '$f' -C '$ROOTDIR'"
      msg "Rollback aplicado: $pkg-$ver"
      return 0
    fi
  done
  err "Pacote não encontrado no cache: $pkg-$ver"
}

# -----------------------------
# Toolchain LFS
# -----------------------------
build_toolchain() {
  info "Construindo toolchain LFS em $LFS/tools"
  mkdir -p "$LFS/tools"
  # Exemplo: usar receitas marcadas com TOOLCHAIN=1 (ex.: gcc-*-toolchain.recipe)
  # Descobre receitas com TOOLCHAIN
  list=$(grep -R "^TOOLCHAIN=1" "$REPO" -n | cut -d: -f1 | sort)
  [ -n "$list" ] || err "Nenhuma receita TOOLCHAIN=1 encontrada"
  for rf in $list; do
    load_recipe "$rf"
    # Força prefixo para $LFS/tools se receita não especificar
    : "${CONFIGURE:=./configure --prefix=$LFS/tools}"
    # Define ambiente LFS típico mínimo
    export LFS_TGT=$(uname -m)-lfs-linux-gnu
    export PATH="$LFS/tools/bin:$PATH"
    build_one "$rf"
  done
  msg "Toolchain LFS concluído em $LFS/tools"
}

# -----------------------------
# Revdep (verifica dependências de libs compartilhadas)
# -----------------------------
revdep_scan() {
  root="$ROOTDIR"
  tmp="$WORKDIR/revdep.txt"; : >"$tmp"
  find "$root" -type f \( -perm -111 -o -name "*.so*" \) 2>/dev/null | while IFS= read -r f; do
    case "$f" in *bin/*|*lib/*) :;; *) continue;; esac
    ldd "$f" 2>/dev/null | awk -v file="$f" '/not found/{print file ":" $0}' >>"$tmp" || true
  done
  if [ -s "$tmp" ]; then
    warn "Bibliotecas não encontradas:"; cat "$tmp"
    # Tentar sugerir pacote dono da lib ausente
    awk -F: '{print $2}' "$tmp" | awk '{print $1}' | sort -u | while read -r lib; do
      owner=$(grep -Rl "/$(basename "$lib")" "$SYSDB/files" 2>/dev/null | sed 's#.*/##;s/\.list$//' | head -n1 || true)
      [ -n "$owner" ] && info "Sugestão: reconstruir pacote $owner"
    done
  else
    msg "Revdep OK: todas as libs resolvidas"
  fi
}

# -----------------------------
# Sync de repositório de receitas via git
# -----------------------------
repo_sync() {
  if [ -d "$REPO/.git" ]; then
    info "Atualizando receitas em $REPO"
    ( cd "$REPO"; git pull --ff-only )
  else
    err "$REPO não é um repositório git. Use: git clone <url> '$REPO'"
  fi
}

# -----------------------------
# Upgrade
# -----------------------------
upgrade_pkg() {
  pkg="$1"
  cur=$(installed_version "$pkg")
  rf=$(find_recipe "$pkg") || err "Receita não encontrada para $pkg"
  load_recipe "$rf"
  new="$VERSION"
  [ "$new" = "$cur" ] && { info "$pkg já na versão $cur"; return 0; }
  info "Atualizando $pkg: $cur -> $new"
  build_one "$rf"
}

upgrade_all() {
  for d in "$SYSDB"/packages/*; do
    [ -d "$d" ] || continue
    pkg=$(basename "$d")
    upgrade_pkg "$pkg"
  done
}

# -----------------------------
# Info
# -----------------------------
show_info() {
  pkg="$1"
  if ! is_installed "$pkg"; then err "$pkg não instalado"; fi
  ver=$(installed_version "$pkg")
  echo "Pacote: $pkg"
  echo "Versão: $ver"
  echo "Arquivos: $SYSDB/files/${pkg}.list"
  echo "Instalado em: $(cat "$(pkgdb_dir "$pkg")/installed_at")"
  if lf=$(log_file_for "$pkg" "$ver"); then [ -f "$lf" ] && echo "Log: $lf"; fi
}

list_installed() {
  for d in "$SYSDB"/packages/*; do [ -d "$d" ] && echo "$(basename "$d") $(cat "$d/version" 2>/dev/null || echo -)"; done | sort
}

# -----------------------------
# Limpeza
# -----------------------------
clean() {
  info "Limpando diretórios de trabalho e logs antigos"
  rm -rf "$WORKDIR"/* 2>/dev/null || true
}

# -----------------------------
# CLI
# -----------------------------
usage() {
  cat <<EOF
Uso: $0 [FLAGS] <comando> [args]

FLAGS gerais:
  --repo DIR           Caminho para receitas (default: $REPO)
  --root DIR           Raiz de instalação (default: $ROOTDIR)
  --work DIR           Diretório de trabalho (default: $WORKDIR)
  --jobs N             Paralelismo do make (default: $JOBS)
  --color (auto|always|never)
  --force              Força reconstrução/instalação
  --no-clean           Mantém diretórios de trabalho
  --quiet              Silencia saídas informativas
  --no-spinner         Desativa spinner

Comandos:
  install PKG[ PKG...]         Resolve deps e instala
  build RECIPE                 Constrói a partir de um arquivo .recipe
  remove PKG                   Remove pacote instalado
  rollback PKG [VER]           Restaura do cache
  info PKG                     Mostra info do pacote
  list                         Lista pacotes instalados
  toolchain                    Constrói toolchain em $LFS/tools
  revdep                       Varre binários/libs por dependências ausentes
  sync                         git pull no repositório de receitas
  upgrade PKG                  Atualiza pacote para última receita
  upgrade-all                  Atualiza todos os pacotes instalados
  clean                        Limpa workdirs
  rebuild-all                  Reconstrói todos os pacotes instalados (usa --force)

Exemplos de layout de receitas:
  $REPO/base/gcc-12.1/gcc-12.1.recipe
  $REPO/base/gcc-12.1/gcc-12.1-toolchain.recipe (TOOLCHAIN=1)
EOF
}

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO="$2"; shift 2;;
      --root) ROOTDIR="$2"; shift 2;;
      --work) WORKDIR="$2"; shift 2;;
      --jobs) JOBS="$2"; shift 2;;
      --color) COLOR="$2"; shift 2;;
      --force) FORCE=1; shift;;
      --no-clean) NOCLEAN=1; shift;;
      --quiet) QUIET=1; shift;;
      --no-spinner) SPINNER=0; shift;;
      -h|--help) usage; exit 0;;
      --) shift; break;;
      *) break;;
    esac
  done
  set -- "$@"
  CMD="${1-}"; shift || true
  ARGS="$@"
}

rebuild_all() {
  FORCE=1
  pkgs=$(list_installed | awk '{print $1}')
  [ -n "$pkgs" ] || { info "Nada instalado"; return 0; }
  install_with_deps $pkgs
}

main() {
  ensure_dirs
  parse_flags "$@"
  case "$CMD" in
    install)      [ -n "$ARGS" ] || err "Informe pacotes"; install_with_deps $ARGS ;;
    build)        [ -n "$ARGS" ] || err "Informe arquivo .recipe"; build_one "$ARGS" ;;
    remove)       [ -n "$ARGS" ] || err "Informe pacote"; remove_pkg "$ARGS" ;;
    rollback)     set -- $ARGS; remove_pkg "$1"; rollback_pkg "$1" "${2-}" ;;
    info)         [ -n "$ARGS" ] || err "Informe pacote"; show_info "$ARGS" ;;
    list)         list_installed ;;
    toolchain)    build_toolchain ;;
    revdep)       revdep_scan ;;
    sync)         repo_sync ;;
    upgrade)      [ -n "$ARGS" ] || err "Informe pacote"; upgrade_pkg "$ARGS" ;;
    upgrade-all)  upgrade_all ;;
    clean)        clean ;;
    rebuild-all)  rebuild_all ;;
    ""|-h|--help) usage ;;
    *)            err "Comando desconhecido: $CMD" ;;
  esac
}

main "$@"
