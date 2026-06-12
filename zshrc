#!/bin/zsh
## Study REF-> https://explainshell.com/

# ==============================================================================
# 🌍 GLOBAL ENVIRONMENTAL VARIABLES / 全域環境變數設定
# ==============================================================================
export LC_ALL=en_US.UTF-8
export LoginDay=$(date +%F)

# Authors / 核心作者 : 
# [Ralic Lo (ralic.lo@gmail.com)
# [NATHANIEL LANDAU] (https://natelandau.com/nathaniel-landaus-resume/)


# ==============================================================================
# 🚀 0. STARTUP SCRIPT MANAGEMENT (HOISTING) / 啟動腳本生命週期管理
# ==============================================================================

# Executed immediately at the beginning of setup / 於配置開頭最先執行的基礎設定
function START_UP@BEGIN() {
    local compl_dir="$HOME/.zsh/completions"

    # 1. 確保補全目錄存在
    if [[ ! -d "$compl_dir" ]]; then
        echo "[Info] START_UP@BEGIN: Creating completions directory... / 正在建立補全目錄..."
        mkdir -p "$compl_dir"
    fi

    # 2. 檢查指令存在，且當補全檔案「不存在」時才生成 
    if (( $+commands[mistralrs] )) && [[ ! -f "$compl_dir/_mistralrs-server" ]]; then
        echo "[Info] START_UP@BEGIN: Generating mistralrs Zsh completion script... / 正在生成 mistralrs 的 Zsh 補全腳本..."
        mistralrs completions zsh > "$compl_dir/_mistralrs-server" 
    fi

    # 3. 驗證補全腳本是否成功生成
    if [[ -f ~/.zsh/completions/_mistralrs-server ]]; then
        echo "[Info] START_UP@BEGIN: Successfully generated mistralrs completion script."
    fi

    # 4. 將自訂補全路徑「提升」至 fpath 的最前端（避免被系統預設路徑蓋過）
    if [[ -d "$compl_dir" ]]; then
        fpath=("$compl_dir" $fpath)
    fi
    echo "[Info] Running boot scripts... / 正在執行初始引導腳本..."     

    # 4. 最後才點火啟動 Zsh 補全系統（此時 _mistralrs-server 已就緒）
    autoload -Uz compinit && compinit

    # 🎯 5. AUTOMATIC COMPLETED VERIFICATION & REPAIR / 自動補全驗證與修復機制    
    # 使用 Zsh 原生關聯陣列語法檢查，速度極快且不產生額外進程
    registered=$(echo $_comps[mistralrs])
    if [[  registered -eq "_mistralrs-server" ]]; then
        echo "[Info] START_UP@BEGIN: Successfully registered mistralrs completion function! / 已成功註冊 mistralrs 的補全功能！"
    else
        # 第一次沒抓到時，強制清除快取並重啟補全引擎（加入安全防護）
        echo "[Warning] mistralrs completion not cached. Refreshing zcompdump... / 未偵測到 mistralrs 補全快取，正在強制重新整理..."
        rm -f "$HOME/.zcompdump"*
        autoload -Uz compinit && compinit -u 2>/dev/null        
        # 再次確認修復結果
        registered=$(echo $_comps[mistralrs])
        if [[  registered -eq "_mistralrs-server" ]]; then
            echo "[Info] START_UP@BEGIN: Successfully registered mistralrs after refresh! / 重新整理後已成功註冊 mistralrs 補全！"
        else
            echo "[Error] Failed to register mistralrs. Please check if the file exists in fpath. / 註冊失敗，請檢查檔案是否存在於 fpath 中。"
        fi
    fi

    # ==============================================================================
    # 🎯 COMPLETION BEHAVIOR CONFIGURATION / 補全行為進階優化
    # ==============================================================================

    # 1. 啟用進階補全選單：按 Tab 會出現可移動光標的清單，而不是直接跳到下一個資料夾
    zstyle ':completion:*' menu select

    # 2. 完美的補全載入順序：確保命令、參數、路徑同時被納入補全考量
    zstyle ':completion:*' completer _expand _complete _ignored _approximate

    # 3. 允許大小寫不敏感補全 (輸入小寫 mistralrs 也能補全大寫路徑/參數)
    zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
}


# ==============================================================================
# 💻 1. DYNAMIC PLATFORM DETECTION / 平台動態偵測與核心數配置
# ==============================================================================
# Detects OS to configure CPU cores ($PACORES), Homebrew paths, and system commands.
# 偵測作業系統以動態配置 CPU 核心線程數 ($PACORES)、Homebrew 路徑與系統相依指令。
if [ "$(uname -s)" = "Linux" ]; then
    # Linux: Parse /proc/cpuinfo to calculate hyper-threaded cores
    # Linux 環境：解析 /proc/cpuinfo 並將邏輯核心數乘以 2 以優化編譯
    SETCC="gcc"
    GCC_VER=15
    PACORES=$(grep -c ^processor /proc/cpuinfo)
    PACORES=$(( PACORES * 2 )) 
    UsrPATH="/home"
    UsrNAME=$(whoami)
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
    export BREW_PREFIX="/home/linuxbrew/.linuxbrew"
    alias make="make \$MAKEJOBS" 
    COLOR_FLAG="--color=auto"
    READLINK="readlink"
elif [ "$(uname -s)" = "Darwin" ]; then
    # macOS: Use sw_vers and sysctl for OS version and CPU cores
    # macOS 環境：使用 sw_vers 與 sysctl 取得系統版本與硬體核心數
    export MACOSX_DEPLOYMENT_TARGET=$(sw_vers -productVersion)
    SETCC="gcc"
    GCC_VER=15
    PACORES=$(sysctl -n hw.ncpu)
    PACORES=$(( PACORES * 2 ))
    UsrPATH="/Users"
    UsrNAME=$(whoami)
    alias f='open -a Finder ./'               
    READLINK="greadlink" # Requires coreutils via Homebrew / 建議使用 Homebrew 安裝 coreutils
    system_VER=64
    export JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null)
    export BREW_PREFIX="/usr/local"
    export BLOCKSIZE=4096
    export PATH="$PATH:/Users/$UsrNAME/.cargo/bin"
    COLOR_FLAG="-G"
fi

# Set Homebrew optimization prefix / 設定 Homebrew 套件優化路徑字首
export OPT_PREFIX="$BREW_PREFIX/opt" 

# 執行引導，先準備好目錄與補全檔案
START_UP@BEGIN

# NOTE: `START_UP@BEGIN` is invoked early during dotfiles loading. Keep it
# lightweight and idempotent: register aliases and inexpensive bindings only.


# ==============================================================================
# 🛠️ 2. FUNCTION DEFINITIONS / 工具函式定義
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCTION: setcc()
# DESCRIPTION: Dynamically switches toolchains & compiler flags (GCC/Clang/MPI).
# 功能描述：動態切換編譯器工具鏈與優化參數設定（支援 GCC、Clang 與 MPI）。
# ------------------------------------------------------------------------------
function setcc() {
    # Initialize with default 'gcc' if $SETCC is empty
    # 若 $SETCC 為空，則初始化賦予預設值 "gcc"
    : "${SETCC:=gcc}"
    
    if [[ $# -eq 1 ]] ; then
        SETCC=$1
    fi
    
    echo "$(tput setaf 6)[Info] Configuring compiler environment... / 正在配置編譯器環境...$(tput sgr0)"
    
    case $SETCC in
        "gcc") ## DEFAULT GNU COMPILER / 預設 GNU 編譯器 ##
            echo "$(tput setaf 3)-> Switching to System Default GCC Environment / 已切換至系統預設 GCC 環境$(tput sgr0)"
            export GCC_FLAGS=" -mmovbe  -m128bit-long-double -msseregparm -mfpmath=sse+387 -mfpmath=both -lpthread"
            export FC="gfortran" CC="gcc" CXX="g++" 
            export CPP="gcc -E" CXXCPP="gcc -E" 
        ;;
        "gccx") ## CUSTOM GCC VERSION / 自訂版本 GNU 編譯器 ##
            echo "$(tput setaf 3)-> Switching to Custom GCC-$GCC_VER Environment / 已切換至自訂 GCC-$GCC_VER 環境$(tput sgr0)"
            export GCC_FLAGS="-mmovbe  -m128bit-long-double -msseregparm -mfpmath=sse+387 -mfpmath=both  -lpthread"
            export FC="gfortran-$GCC_VER" CC="gcc-$GCC_VER" CXX="g++-$GCC_VER"
            export CPP="gcc-$GCC_VER -E" CXXCPP="g++-$GCC_VER -E"
            export HOMEBREW_CC="gcc-$GCC_VER"
        ;;
        "clang")  ## CLANG/LLVM COMPILER / Clang 與 LLVM 編譯器 ##
            echo "$(tput setaf 3)-> Switching to Clang/LLVM Environment / 已切換至 Clang/LLVM 編譯環境$(tput sgr0)"
            export FC="gfortran" CC="cc" CXX="c++" 
            export CPP="clang -E" CXXCPP="clang++ -E"
            export HOMEBREW_CC="clang"
        ;;
        "mpicc") ## MPI HIGH-PERFORMANCE COMPUTING / HPC 高效能平行運算 MPI ##
            echo "$(tput setaf 3)-> Switching to MPI Environment / 已切換至 MPI 高效能平行運算環境$(tput sgr0)"
            export FC="mpifort" CC="mpicc" CXX="mpicxx" 
            export CPP="mpicc -E " CXXCPP="mpicxx -E"  
            export MPIFC="mpifort" MPICC="mpicc" MPICPP="mpicc -E" MPICXX="mpicxx"
            export HOMEBREW_CC="mpicc" HOMEBREW_CXX="mpicxx"
        ;;
        *) ## UNKNOWN OPTION FALLBACK / 未知選項防禦機制 ##
            echo "$(tput setaf 1)[Warning] Unknown compiler option: '$SETCC'. No settings applied. / 未知的編譯器選項，未套用任何變更。$(tput sgr0)"
        ;;
    esac
    
    # Status output summary / 終端機狀態輸出總結
    printf "%s[Success] setcc completed. CURRENT SETCC=%s, PACORES=%s%s\n" \
        "$(tput setaf 2)" "$SETCC" "$PACORES" "$(tput sgr0)"
}

# ------------------------------------------------------------------------------
# FUNCTION: cheditor()
# DESCRIPTION: Changes the default terminal text editor environment variable.
# 功能描述：快速變更終端機的預設文字編輯器環境變數（預設為 Sublime Text）。
# ------------------------------------------------------------------------------
function cheditor() {
    echo "[Info] cheditor: Script to change your default terminal editor / 正在切換預設終端機編輯器"
    if [[ $# -eq 0 ]] ; then
        local VAR_EDITOR=subl   
    else
        local VAR_EDITOR="$@"
    fi
    export TEXT_Editor=$VAR_EDITOR
    export EDITOR=$VAR_EDITOR
}


# ==============================================================================
# 🎨 3. INTERACTIVE PROMPT SETUP (PS1) / 雙行美化提示字元設定
# ==============================================================================
# Enable prompt expansion for dynamic variables
# 啟用 PROMPT_SUBST，確保 Zsh 提示字元中的變數與函式能在每次顯示時動態展開
setopt PROMPT_SUBST

# Fetch user identity and hostname / 取得使用者身分與主機名稱
USER=$(id -un)
HOSTNAME=$(uname -n)

# Escape non-printable control characters with %{ ... %} to prevent cursor drifting bugs.
# 使用 Zsh 專屬的 %{ ... %} 包裹 tput 顏色控制碼，完美防止長指令換行時游標錯位或重疊。
local BOLD="%{$(tput bold)%}"
local CYAN="%{$(tput setaf 6)%}"
local BLUE="%{$(tput setaf 4)%}"
local RESET="%{$(tput sgr0)%}"

# PS1 Multi-line Layout Design / 雙行排版設計
# Upper line: Full horizontal divider line followed by working directory, host, and user info.
# Lower line: Clean input area starting with '=>'.
export PS1='________________________________________________________________________________
${BOLD}${CYAN}%d ${CYAN}@${HOSTNAME} ${BLUE}(${USER})${RESET}
=>'

# Synchronize setup to sudo sessions / 將提示字元設定同步套用至 sudo 權限環境
export SUDO_PS=$PS1


# ==============================================================================
# 📂 DIRECTORY NAVIGATION ENHANCEMENTS / 目錄導覽功能增強
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCTION: cd()
# DESCRIPTION: Overrides the built-in 'cd' to automatically save the previous 
#              directory path ($prevfolder) before switching to the new one.
#              (Tip: To always list directory contents upon 'cd', 'ls' can be added).
# 功能描述：覆寫系統內建的 'cd' 指令。在切換至新目錄前，會自動將「當前路徑」
#          暫存至 $prevfolder 變數中，以便進行來回快速切換。
# ------------------------------------------------------------------------------
cd() { 
    prevfolder=$(pwd)
    builtin cd "$@"
    # If you want to automatically 'ls' after every 'cd', uncomment the line below:
    ls ${COLOR_FLAG}
} 

# Record the initial login directory snapshot
# 紀錄剛開啟終端機時的初始登入路徑快照
termfolder=$(pwd)

# ------------------------------------------------------------------------------
# ALIASES: orig & prev
# DESCRIPTION: Shortcuts for quick directory navigation.
#              - orig: Instantly jump back to the terminal-login root directory.
#              - prev: Toggle/switch back to the immediately preceding directory.
# 別名設定：快速目錄導覽捷徑。
#          - orig: 瞬間返回開啟此終端機視窗時的初始登入目錄。
#          - prev: 在最近切換的兩個資料夾目錄之間，進行快速來回切換 (2017/07/30)。
# ------------------------------------------------------------------------------
alias orig='cd $termfolder' 
alias prev='cd $prevfolder'


# ==============================================================================
# 📂 FILE AND FOLDER MANAGEMENT / 檔案與資料夾管理
# ==============================================================================

# ------------------------------------------------------------------------------
# ALIAS: nofiles
# DESCRIPTION: Counts and displays the total number of non-hidden files in the 
#              current directory using efficient Zsh glob modifiers.
# 功能描述：計算並顯示當前目錄下的「非隱藏檔案」總數。此指令採用 Zsh 內建的 
#          球狀擴充（Globbing）機制，比傳統的 'ls' 遞迴更有效率。
# ------------------------------------------------------------------------------
alias nofiles='echo "Total files in directory: $(print -l *(.) | wc -l)"'

# ------------------------------------------------------------------------------
# ALIAS: make1mb / make5mb / make10mb
# DESCRIPTION: Creates a dummy file of a specified size (1MB, 5MB, or 10MB) 
#              filled with zeros using the macOS native 'mkfile' utility.
#              (Note: Size suffixes must be uppercase like M or G on macOS).
# 功能描述：使用 macOS 內建的 'mkfile' 工具建立指定大小（1MB、5MB 或 10MB）
#          的測試空檔案（內容全為零）。注意：macOS 系統的單位必須大寫。
# ------------------------------------------------------------------------------
alias make1mb='mkfile 1M ./1MB.dat'
alias make5mb='mkfile 5M ./5MB.dat'
alias make10mb='mkfile 10M ./10MB.dat'

# 快捷建立 RAM Disk 函數 / Quick RAM Disk Function
function makeram() {
    # 確保 /tmp/RAMDisk 存在以避免 hdiutil 錯誤 / Ensure /tmp/RAMDisk exists to prevent hdiutil errors
    # 檢查是否已經掛載了相同名稱的 RAMDisk (檢查路徑是否存在)
    if [ -e "/tmp/RAMDisk" ]; then
        echo "[Warning] RAMDisk 正在掛載中 / RAMDisk is already mounted!"
        echo "若有必須請先執行 / Please run: diskutil eject /Volumes/RAMDisk if necessary"
        return 1
    fi
    touch /tmp/RAMDisk 2>/dev/null 
    
    local gb=${1:-2} # 預設 2GB / Default 2GB
    local sectors=$(( gb * 1024 * 1024 * 1024 / 512 ))
    
    echo "正在建立 ${gb}GB 記憶體磁碟... / Allocating ${gb}GB RAM Disk..."
    
    # 1. 嘗試配置記憶體 / Attempt to attach memory
    local dev
    dev=$(hdiutil attach -nomount ram://$sectors | tr -d '[:space:]')
    if [ $? -ne 0 ] || [ -z "$dev" ]; then
        echo "[Error] 記憶體配置失敗！ / Failed to allocate memory via hdiutil!"
        return 1
    fi
    
    # 2. 嘗試建立 APFS 磁碟區 / Attempt to create APFS volume
    if diskutil apfs create $dev RAMDisk > /dev/null; then
        echo "成功！掛載點位於: /Volumes/RAMDisk / Success! Mounted at: /Volumes/RAMDisk"
    else
        echo "[Error] APFS 格式化失敗！ / Failed to format volume as APFS!"
        # 額外防呆：如果格式化失敗，自動釋放剛剛配置成功的記憶體裝置
        # Fallback: If format fails, automatically detach the allocated ram device
        hdiutil detach "$dev" 2>/dev/null
        return 1
    fi
}

# ------------------------------------------------------------------------------
# ALIAS: fsize
# DESCRIPTION: Lists all files in the current directory, detailed with human-
#              readable sizes, and automatically sorted from largest to smallest.
# 功能描述：列出當前目錄下的所有檔案詳細資訊，並自動依據檔案大小「由大到小」
#          進行排序，且檔案大小會以易讀的單位（如 KB, MB）顯示。
# ------------------------------------------------------------------------------
alias fsize='ls -lh *(oL.)'
alias dsize='du -sh'

# ------------------------------------------------------------------------------
# FUNCTION: trash()
# DESCRIPTION: Safely moves specified files or folders to the macOS native 
#              Trash folder (~/.Trash) instead of permanently deleting them.
# 功能描述：安全刪除工具。將指定的檔案或資料夾移至 macOS 內建的「垃圾桶」
#          （~/.Trash），避免因誤用系統的 'rm' 指令而導致檔案永久遺失。
# ------------------------------------------------------------------------------
trash () { 
    command mv "$@" ~/.Trash ; 
}

# ==============================================================================
# 📦 ARCHIVE EXTRACTION UTILITIES / 壓縮檔解包自動化工具
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCTION: extract()
# DESCRIPTION: A smart, single-command utility to automatically detect and 
#              extract almost all known archive formats based on their extensions.
#              (Supports: .tar.lz4, .tar.xz, .tar.bz2, .tar.gz, .bz2, .rar, .gz, 
#               .tar, .tbz2, .tgz, .zip, .Z, .xz, .7z, .lz4, .lzma)
# 功能描述：智慧型萬用解壓功能。只需單一指令，即可自動根據副檔名判別並解開絕
#          大多數常見的壓縮檔格式，省去記憶各種不同解壓參數的麻煩。
# ------------------------------------------------------------------------------
extract () {
    if [ -f "$1" ] ; then
        case "$1" in
            *.lzfse.bvx3)      echo "lzfse -decode -i $1 -so -algo bvx3   | tar -xf - " ; lzfse -decode -i $1 -so -algo bvx3   | tar -xf -  ;;   
            *.lzfse.other3)    echo "lzfse -decode -i $1 -so -algo other3 | tar -xf - " ; lzfse -decode -i $1 -so -algo other3 | tar -xf -  ;;  
            *.lzfse.apple)     echo "lzfse -decode -i $1 -so -algo apple  | tar -xf - " ; lzfse -decode -i $1 -so -algo apple  | tar -xf -  ;;
            *.tar.lz4)   lz4 -T0 -d -q -c $1 | tar -xf - ;;
            *.zst)       zstd -d -c "$1" | tar -xf - ;;
            *.tar.xz)    tar xf "$1"      ;;
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    tar xzf "$1"     ;;
            *.tgz)       tar xzf "$1"     ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar e "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       tar xzf "$1"     ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.xz)        xz -d "$1"       ;;
            *.7z)        7z x "$1"        ;;
            *.lz4)       unlz4 "$1"       ;;
            *.lzma)      tar --lzma -xvf "$1" ;;
            *.lz4a)      unlz4a "$1"        ;;
            *)           echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

function nanoTimeElapsed() {
    zmodload zsh/datetime
    local start_time end_time elapsed
    # 擷取開始時間（秒.微秒浮點數） / Capture start time (Seconds.Microseconds float)
    start_time=$EPOCHREALTIME
    # 執行目標命令 / Execute target command
    "$@"
    end_time=$EPOCHREALTIME
    
    # 計算時間差並轉換為奈秒 (1 秒 = 1,000,000,000 奈秒)
    # 使用 awk 處理浮點數運算以確保跨平台精確度
    # Calculate time difference and convert to nanoseconds (1 sec = 1,000,000,000 ns)
    # Use awk for floating-point math to ensure cross-platform precision
    elapsed_ns=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { printf "%010.0f", (end - start) * 1000000000 }')
    echo "==> Process $@ took: ${elapsed_ns} 奈秒/nanoseconds"
}


# ------------------------------------------------------------------------------
# FUNCTION: ffilter()
# DESCRIPTION: Escapes spaces, single quotes, and double quotes in file paths 
#              passed via standard input. Often used as a reliable fallback 
#              when 'find -print0' or standard xargs arguments fail.
# 功能描述：路徑字元跳脫過濾器。自動將標準輸入（stdin）中的空白字元、單引號、
#          雙引號加上反斜線（\）進行跳脫，專門用來解決路徑包含特殊字元時，
#          'find -print0' 或 xargs 處理失敗的痛點。
# ------------------------------------------------------------------------------
function ffilter() {
    sed -e "s/'/\\\'/g" -e 's/"/\\\"/g' -e 's/ /\\ /g' 
}

# ==============================================================================
# 🗜️ COMPRESSION TOOLS / 目錄壓縮工具
# ==============================================================================

## This script helps to creat a tar.xz for a folder.
function getar() {
    XZ_OPT=-e9 tar czf "$1".tgz "$1"
    du -sh $1
    du -sh $1.tgz
}

function lzfseX() {
    # 如果參數 $1 為空則提示並退出
    if [[ -z "$1" ]]; then
        echo "使用方法: lzfseX <檔案或目錄> [演算法]"
        return 1
    fi

    # 設置預設值為 'other' (若 $2 為空)
    local algo="${2:-other3}"
    
    # 若演算法為 apple，副檔名為 lzfse.apple，否則為 lzfse
    local extension="lzfse.other3"
    [[ "$algo" == "apple" ]] && extension="lzfse.apple"
    [[ "$algo" == "bvx3" ]] && extension="lzfse.bvx3"
    [[ "$algo" == "other3" ]] && extension="lzfse.other3" 

    # 執行壓縮
    echo tar -cf - $1 "|" lzfse -encode -si -o $1.$extension -algo $algo
    tar -cf - "$1" | lzfse -encode -si -o "$1.$extension" -algo "$algo"
    
    # 顯示檔案大小
    echo "--- 壓縮資訊 ---"
    du -sh "$1"
    du -sh "$1.$extension"
}

function getzstd() {
   tar -cf - $1 | zstd -9 -T0 -c > $1.zst
    # tar -I 'zstd -1' -cvf $1.zst $1
    du -sh $1
    du -sh $1.zst
}

function tlz4() {
    tar -cf - $1 | lz4 -T0 -6 -q > $1.tar.lz4
    # tar --use-compress-program=lz4 -cf  $1.tar.lz4 $1
    du -sh $1
    du -sh $1.tar.lz4 
}

# ------------------------------------------------------------------------------
# FUNCTION: lz4bench()
# DESCRIPTION: Benchmarks and compares the performance (speed and execution time)
#              between 'lz4a','tgz', 'tlz4' ,'getzstd' using precise 'date' timestamps.
#
# 功能描述：壓縮效能基準測試。利用 'date' 時間戳記精準計算並比較 'lz4a' ,'tgz', 'tlz4' ,'getzstd'
#        在壓縮與解壓縮過程中的實際耗時（秒）。
# ------------------------------------------------------------------------------
function lz4bench() {
    # 檢查是否輸入測試目標 / Check if input target is specified
    if [[ -z "$1" ]]; then
        echo "錯誤: 請指定要測試的目錄 / Error: Please specify a directory to benchmark" >&2
        return 1
    fi
    echo $'[Info] 開始執行 tgz, lzfse, tlz4, zstd 基準測試 / Starting benchmark for tgz, lzfse, tlz4, zstd...\n'

    # --------------------------------------------------------------------------
    # 1.測試 getar 壓縮速度 / Test lz4a compression speed
    # --------------------------------------------------------------------------
    echo $'\n[Info] 測試 getar 壓縮 / Testing getar compression:'
    nanoTimeElapsed getar $1

    # --------------------------------------------------------------------------
    # 1. 測試 lzfse 壓縮速度 / Test lzfseX compression speed
    # --------------------------------------------------------------------------
    
    echo $'\n[Info] 測試 lzfseX other3 壓縮 / Testing lzfseX other3 compression:'
    nanoTimeElapsed lzfseX $1 other3
    
    echo $'\n[Info] 測試 lzfseX bvx3 壓縮 / Testing lzfseX bvx3 compression:'
    nanoTimeElapsed lzfseX $1 bvx3

    echo $'\n[Info] 測試 lzfseX apple 壓縮 / Testing lzfseX apple compression:'
    nanoTimeElapsed lzfseX $1 apple

    # --------------------------------------------------------------------------
    # 1. 測試 tlz4 壓縮速度 / Test lz4a compression speed
    # --------------------------------------------------------------------------
    echo $'\n[Info] 測試 tlz4  壓縮 / Testing tlz4 compression:'
    nanoTimeElapsed tlz4 $1

    # --------------------------------------------------------------------------
    # 1. 測試 zstd 壓縮速度 / Test lz4a compression speed
    # --------------------------------------------------------------------------
    echo $'\n[Info] 測試 zstd  壓縮 / Testing zstd compression:'
    nanoTimeElapsed getzstd $1

    echo $'\n=================================================='
    echo $'[Info] 開始評測解壓縮速度 / Benchmarking decompression score:'
    echo $'=================================================='

    # --------------------------------------------------------------------------
    # 2. 測試 tgz 解壓速度 / Test tgz decompression speed
    # --------------------------------------------------------------------------
    mkdir -p ./xbenchTest/tgz  > /dev/null 2>&1
    cp "$1.tgz" ./xbenchTest/tgz > /dev/null 2>&1
    cd ./xbenchTest/tgz > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1

    echo $'\n[Info] 測試 tgz 解壓 / Testing tgz extraction:'
    echo nanoTimeElapsed extract $1.tgz
    nanoTimeElapsed extract $1.tgz 
    cd ../.. > /dev/null 2>&1

    # --------------------------------------------------------------------------
    # 2. 測試 lzfseX 解壓速度 / Test lzfseX decompression speed
    # --------------------------------------------------------------------------

    mkdir -p ./xbenchTest/lzfse_other3 > /dev/null 2>&1
    cp $1.lzfse.other3 ./xbenchTest/lzfse_other3 > /dev/null 2>&1
    cd ./xbenchTest/lzfse_other3 > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1
 
    echo $'\n[Info] 測試 lzfse.other3 解壓 / Testing lzfse.other3 extraction:'
    echo nanoTimeElapsed extract $1.lzfse.other3
    nanoTimeElapsed extract $1.lzfse.other3
    cd ../.. > /dev/null 2>&1


    mkdir -p ./xbenchTest/lzfse_bvx3 > /dev/null 2>&1
    cp $1.lzfse.bvx3 ./xbenchTest/lzfse_bvx3 > /dev/null 2>&1
    cd ./xbenchTest/lzfse_bvx3 > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1
 
    echo $'\n[Info] 測試 lzfse.bvx3 解壓 / Testing lzfse.bvx3 extraction:'
    echo nanoTimeElapsed extract $1.lzfse.bvx3
    nanoTimeElapsed extract $1.lzfse.bvx3
    cd ../.. > /dev/null 2>&1

    mkdir -p ./xbenchTest/lzfse_apple > /dev/null 2>&1
    cp $1.lzfse.apple ./xbenchTest/lzfse_apple > /dev/null 2>&1
    cd ./xbenchTest/lzfse_apple > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1
    
    echo $'\n[Info] 測試 lzfse.apple 解壓 / Testing lzfse.apple extraction:' 
    echo nanoTimeElapsed extract $1.lzfse.apple
    nanoTimeElapsed extract $1.lzfse.apple
    cd ../.. > /dev/null 2>&1

    # --------------------------------------------------------------------------
    # 2. 測試 tlz4 解壓速度 / Test tlz4 decompression speed
    # --------------------------------------------------------------------------
    mkdir -p ./xbenchTest/tlz4 > /dev/null 2>&1
    cp $1.tar.lz4 ./xbenchTest/tlz4 > /dev/null 2>&1
    cd ./xbenchTest/tlz4 > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1
    
    echo $'\n[Info] 測試 tlz4 解壓 / Testing tlz4 extraction:' 
    echo nanoTimeElapsed extract $1.tar.lz4
    nanoTimeElapsed extract $1.tar.lz4
    cd ../.. > /dev/null 2>&1

    # --------------------------------------------------------------------------
    # 2. 測試 zstd 解壓速度 / Test zstd decompression speed
    # --------------------------------------------------------------------------
    mkdir -p ./xbenchTest/zstd > /dev/null 2>&1
    cp $1.zst ./xbenchTest/zstd > /dev/null 2>&1
    cd ./xbenchTest/zstd > /dev/null 2>&1
    rm -rf $1 > /dev/null 2>&1
    
    echo $'\n[Info] 測試 zstd 解壓 / Testing zstd extraction:' 
    echo nanoTimeElapsed extract $1.zst
    nanoTimeElapsed extract $1.zst
    cd ../.. > /dev/null 2>&1

    # --------------------------------------------------------------------------
    # 3. 環境環境清理 / Sandbox cleanup
    # --------------------------------------------------------------------------
    diff -rq ./xbenchTest/tgz/$1 ./xbenchTest/tlz4/$1 > /dev/null 2>&1 && echo $'\n[Success] tgz,tlz4 解壓後的內容完全一致！ / Decompressed contents are identical!' || echo $'\n[Warning] tgz,tlz4  解壓後的內容不一致！ / tgz,tlz4 Decompressed contents differ!'
    diff -rq ./xbenchTest/tgz/$1 ./xbenchTest/lzfse_other3/$1 > /dev/null 2>&1 && echo $'\n[Success] tgz,lzfse_other3 解壓後的內容完全一致！ / Decompressed contents are identical!' || echo $'\n[Warning] tgz,lzfse_other3  解壓後的內容不一致！ / tgz,lzfse_other3 Decompressed contents differ!'
    diff -rq ./xbenchTest/tgz/$1 ./xbenchTest/lzfse_bvx3/$1 > /dev/null 2>&1 && echo $'\n[Success] tgz,lzfse_bvx3 解壓後的內容完全一致！ / Decompressed contents are identical!' || echo $'\n[Warning] tgz,lzfse_bvx3  解壓後的內容不一致！ / tgz,lzfse_bvx3 Decompressed contents differ!'
    diff -rq ./xbenchTest/tgz/$1 ./xbenchTest/lzfse_apple/$1 > /dev/null 2>&1 && echo $'\n[Success] tgz,lzfse_apple 解壓後的內容完全一致！ / Decompressed contents are identical!' || echo $'\n[Warning] tgz,lzfse  解壓後的內容不一致！ / tgz,lzfse Decompressed contents differ!'
    diff -rq ./xbenchTest/tgz/$1 ./xbenchTest/zstd/$1 > /dev/null 2>&1 && echo $'\n[Success] tgz,zstd 解壓後的內容完全一致！ / Decompressed contents are identical!' || echo $'\n[Warning] tgz,zstd  解壓後的內容不一致！ / tgz,zstd Decompressed contents differ!'

    # rm -rf xbenchTest
    
    echo $'\n[Info] 基準測試完成！ / Benchmark finished!'
}

function claudeCodeEnv(){
    # 1. 將 API 導向你的本地 llama-server
    export ANTHROPIC_BASE_URL="http://127.0.0.1:8080"

    # 2. 本地不需要真正的 Key，隨便填一個偽裝字串即可
    export ANTHROPIC_API_KEY="JesusLoveYou"
    export OPENAI_API_KEY="JesusLoveYou"
    
    # 3. 覆蓋 Claude Code 的預設模型別名（強迫它對應到你的本地模型）
    export ANTHROPIC_DEFAULT_SONNET_MODEL="gemma-4"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="gemma-4"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="gemma-4"
    export CLAUDE_CODE_SUBAGENT_MODEL="gemma-4"
    # 4. 如果你的代理/後端支援工具呼叫，開啟 MCP 工具搜尋（本地實驗性功能）
    export ENABLE_TOOL_SEARCH=true
    # 5. 確保目標資料夾存在
    mkdir -p ~/.claude

    # 6. 使用 tee 寫入 JSON
cat << 'EOF' | tee ~/.claude/settings.json
{
"env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
    "ANTHROPIC_API_KEY": "JesusLoveYou",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gemma-4",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gemma-4",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gemma-4",
    "CLAUDE_CODE_SUBAGENT_MODEL": "gemma-4"
    },
  "theme": "dark"
}
EOF

}

function gemma4(){
    claude --model gemma-4
}

# Executed at the end of setup to finalize environment injection / 於配置末尾執行，完成最終環境導入
function START_UP@END() {
    # Bind xargs to scale perfectly with system core threads / 平行化 xargs 執行緒動態綁定
    alias xxargs="xargs -n 1 -P $PACORES"
    alias sll=subl
    setcc          # Apply chosen toolchain setup / 導入選定的編譯器工具鏈
    cheditor vi > /dev/null # Fallback text editor to vi / 設定預設後備編輯器為 vi
    export MAKEJOBS="-j16"  # Parallel compilation limit / 限制平行編譯最大執行緒數
    alias cgrep="grep --color=always"
    # printenv       # Output environment map on terminal login / 登入時印出當前環境變數快照
    # makeram
    diskutil list | grep "RAMDisk" -B4 | grep "/dev" | awk '{print $1}' | tail -n +2 | xargs -I {} diskutil eject {}
    # claudeCodeEnv 2>&1 > /dev/null
}

START_UP@END
source ~/.hf_token

# NOTE: `START_UP@END` finalizes environment injection: it sets conservative
# defaults (e.g., `MAKEJOBS`), applies `setcc`, and defines aliases used in
# interactive shells. It is safe to re-run but should avoid heavy side-effects.