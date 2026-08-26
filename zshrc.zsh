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
}

function zshCompletions() {

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
    # Default to Homebrew clang so builds use one toolchain instead of mixing
    # /usr/bin/gcc (an Apple clang wrapper) with the newer Homebrew LLVM.
    # 預設使用 Homebrew clang，避免建置時混用 /usr/bin/gcc（Apple clang 包裝）
    # 與較新的 Homebrew LLVM 兩套工具鏈。
    SETCC="clang"
    GCC_VER=15
    PACORES=$(sysctl -n hw.ncpu)
    PACORES=$(( PACORES * 2 ))
    UsrPATH="/Users"
    UsrNAME=$(whoami)
    alias f='open -a Finder ./'               
    READLINK="greadlink" # Requires coreutils via Homebrew / 建議使用 Homebrew 安裝 coreutils
    system_VER=64
    export JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null)
    if [[ -x /opt/homebrew/bin/brew ]]; then
        export BREW_PREFIX="$(/opt/homebrew/bin/brew --prefix)"
    elif [[ -x /usr/local/bin/brew ]]; then
        export BREW_PREFIX="$(/usr/local/bin/brew --prefix)"
    else
        export BREW_PREFIX="/opt/homebrew"
    fi
    export BLOCKSIZE=4096
    if [[ -d "$BREW_PREFIX/opt/llvm/bin" ]]; then
        export PATH="$BREW_PREFIX/opt/llvm/bin:$PATH"
    fi
    export PATH="$PATH:/Users/$UsrNAME/.cargo/bin"
    COLOR_FLAG="-G"
else
    case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Windows under MSYS/Cygwin zsh. Without this branch neither of the two
        # above matched, leaving PACORES, UsrPATH, UsrNAME, READLINK and
        # COLOR_FLAG unset: anything deriving a thread count from PACORES fell
        # back to an empty value rather than to the machine's core count.
        # MSYS／Cygwin zsh 下的 Windows。缺少本分支時上述兩者皆不符合，PACORES、
        # UsrPATH、UsrNAME、READLINK 與 COLOR_FLAG 全部未設定：任何以 PACORES
        # 推導執行緒數的地方會取到空值，而非機器的核心數。
        SETCC="gcc"
        GCC_VER=15
        PACORES=${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null)}
        PACORES=${PACORES:-1}
        UsrPATH="/c/Users"
        UsrNAME=$(whoami)
        # No Homebrew here; OPT_PREFIX below is derived from BREW_PREFIX, so it
        # is pointed at the MSYS tree to keep that derivation meaningful.
        # 此處沒有 Homebrew；下方的 OPT_PREFIX 由 BREW_PREFIX 推導，故指向 MSYS
        # 樹狀目錄，使該推導仍具意義。
        export BREW_PREFIX="/usr"
        export BLOCKSIZE=4096
        # GNU coreutils readlink is the native one here, unlike macOS where the
        # BSD version requires greadlink from Homebrew.
        # 此處的 readlink 原生即為 GNU coreutils 版本，不像 macOS 的 BSD 版需另外
        # 安裝 Homebrew 的 greadlink。
        READLINK="readlink"
        system_VER=64
        COLOR_FLAG="--color=auto"
        ;;
    esac
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
            # Pin to Homebrew LLVM by absolute path. Bare "cc"/"clang" resolve
            # differently: cc is always Apple clang, while clang follows PATH.
            # Fall back to the system compiler when Homebrew LLVM is absent.
            # 以絕對路徑指向 Homebrew LLVM。裸寫 "cc"/"clang" 的解析結果不同：
            # cc 一定是 Apple clang，clang 則跟隨 PATH。若無 Homebrew LLVM 則退回系統編譯器。
            if [[ -x "$BREW_PREFIX/opt/llvm/bin/clang" ]]; then
                export CC="$BREW_PREFIX/opt/llvm/bin/clang"
                export CXX="$BREW_PREFIX/opt/llvm/bin/clang++"
            else
                export CC="cc" CXX="c++"
            fi
            export FC="gfortran"
            export CPP="$CC -E" CXXCPP="$CXX -E"
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
#
# Windows uses zsh's own prompt escapes instead of the tput colours above. The
# %{ %} zero-width markers are processed in an earlier pass than $-expansion, so
# a colour arriving through ${BOLD} and friends is no longer honoured as
# zero-width: zsh counts the invisible colour bytes as visible width, the cursor
# drifts, and on the slower Windows console typed keys get dropped or
# scrambled. Native escapes are counted as zero-width correctly.
# Windows 改用 zsh 原生 prompt 跳脫序列，而非上方的 tput 色碼。%{ %} 零寬標記的
# 處理階段早於 $ 展開，因此經由 ${BOLD} 等變數傳入的色碼不再被視為零寬：zsh 會把
# 不可見的色碼位元組算成可見寬度，造成游標偏移，在較慢的 Windows console 上更會
# 吞字或打亂輸入。原生跳脫序列則能被正確視為零寬。
#
# The two forms render the same prompt: %d is the working directory, %m the host
# and %n the user, matching ${HOSTNAME} and ${USER} above.
# 兩種寫法呈現相同的提示字元：%d 為工作目錄、%m 為主機名稱、%n 為使用者，與上方的
# ${HOSTNAME}、${USER} 對應。
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        export PS1='________________________________________________________________________________
%B%F{cyan}%d %F{cyan}@%m %F{blue}(%n)%f%b
=>'
        ;;
    *)
        export PS1='________________________________________________________________________________
${BOLD}${CYAN}%d ${CYAN}@${HOSTNAME} ${BLUE}(${USER})${RESET}
=>'
        ;;
esac

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

# ------------------------------------------------------------------------------
# FUNCTION: open()   [Windows only / 僅限 Windows]
# DESCRIPTION: macOS-style `open`, backed by Windows Explorer, so the same
#              command works on either platform.
# 功能描述：以 Windows Explorer 實作的 macOS 風格 `open`，使同一道指令在兩個平台
#          皆可使用。
#
#   open              current directory / 目前目錄
#   open <dir>        that folder / 該資料夾
#   open <file>       the file's default application / 該檔案的預設應用程式
#   open <url>        the default browser / 預設瀏覽器
#   open -R <path>    reveal the item, selected, in its parent folder
#                     在上層資料夾中選取並顯示該項目
#
# Defined only on Windows. macOS already ships `open`, and shadowing it would
# break -a, -e, -t and its other flags.
# 僅在 Windows 定義。macOS 本身即有 `open`，覆寫它會使 -a、-e、-t 等旗標失效。
#
# Paths go through `cygpath -w`: Explorer cannot read MSYS paths such as
# /c/Users, and handing it one opens the wrong place without reporting an error.
# 路徑一律經 `cygpath -w` 轉換：Explorer 無法解讀 /c/Users 這類 MSYS 路徑，直接
# 傳入會靜默開到錯誤的位置而不報錯。
#
# explorer.exe exits 1 whether or not it succeeded -- verified: a real folder
# and a nonexistent path both return 1 -- so its status carries no information.
# It is discarded and the path is validated here, which is what makes this
# function's own exit status meaningful.
# explorer.exe 不論成功與否都回傳 1——實測：真實資料夾與不存在的路徑皆為 1——其
# 結束碼因此不帶任何資訊。故予以捨棄，改由本函式自行驗證路徑，使本函式的結束碼
# 才具意義。
#
# `-a <app>` is not implemented; invoke the application directly.
# 未實作 `-a <app>`；請直接呼叫該應用程式。
# ------------------------------------------------------------------------------
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        function open() {
            emulate -L zsh
            local reveal=0
            if [[ $1 == -R ]]; then
                reveal=1
                shift
            fi
            local target=${1:-.}

            if [[ -e $target ]]; then
                local win
                win=$(cygpath -w -a -- "$target") || return 1
                if (( reveal )); then
                    explorer.exe "/select,$win"
                else
                    explorer.exe "$win"
                fi
                return 0
            fi

            # Not an existing path: hand schemes such as https:// or mailto: to
            # Explorer, which routes them to the registered handler. cygpath
            # would corrupt these.
            # 不是既有路徑：https://、mailto: 等 scheme 交給 Explorer，由它轉給已
            # 註冊的處理程式；這些字串經 cygpath 會被破壞。
            if [[ $target == *://* || $target == mailto:* ]]; then
                if (( reveal )); then
                    print -u2 -- "open: -R needs a path, not a URL / -R 需要路徑而非 URL"
                    return 1
                fi
                explorer.exe "$target"
                return 0
            fi

            print -u2 -- "open: no such file or directory: $target"
            return 1
        }
        ;;
esac

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
    if [[ -z "$1" ]]; then
        echo "使用方法: extract <archive> [probe]"
        return 1
    fi

    if [[ -f "$1" ]] ; then
        local n_args=()
        if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
            n_args=(-n "$LZFSE_BENCH_N")
        fi
        # 記憶體峰值量測模式：extract <file> probe → 只量「解碼程序」peak RSS，不真正解壓。
        # 解碼輸出寫 /dev/null（不經 tar 管線），確保 time -l 量到的是 lzfse 本身。
        if [[ "$2" == "probe" ]]; then
            local da arg2
            case "$1" in
                *.lzfse.bvx3.lazy2)   da=bvx3; arg2=lazy2 ;;
                *.lzfse.bvx3.optimal) da=bvx3; arg2=optimal ;;
                *.lzfse.other3.optimal3) da=other3 ;;
                *.lzfse.bvx3)         da=bvx3 ;;
                *.lzfse.other3)       da=other3 ;;
                *.lzfse.apple)        da=apple ;;
                *.tgz)
                    if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
                        [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zlib probe requires SWIFT_TAR_BIN." >&2; return 1; }
                        memProbe "decode ${1##*/}" "$SWIFT_TAR_BIN" tzf "$1"
                    else
                        memProbe "decode ${1##*/}" tar tzf "$1"
                    fi
                    return 0
                    ;;
                *.zst)
                    if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
                        [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zstd probe requires SWIFT_TAR_BIN." >&2; return 1; }
                        memProbe "decode ${1##*/}" "$SWIFT_TAR_BIN" -t -f "$1"
                    else
                        memProbe "decode ${1##*/}" tar tzf "$1"
                    fi
                    return 0
                    ;;
                *.tar.lz4)            memProbe "decode ${1##*/}" lz4 -d -q -f "$1" /dev/null; return 0 ;;
                *) echo "[MEM] $1: 非 lzfse 格式，略過解碼量測 / non-lzfse, skipped"; return 0 ;;
            esac
            memProbe "decode ${1##*/}${LZFSE_BENCH_N:+ -n ${LZFSE_BENCH_N}}" \
                lzfse -decode -i "$1" -o /dev/null -algo "$da" ${arg2:+-$arg2} "${n_args[@]}"
            return 0
        fi
        case "$1" in
            *.lzfse.bvx3.lazy2) echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.bvx3.optimal) echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.bvx3)       echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.other3.optimal3) echo "lzfse -decode -i $1 -so -algo other3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo other3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.other3)     echo "lzfse -decode -i $1 -so -algo other3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo other3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.apple)      echo "lzfse -decode -i $1 -so -algo apple ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo apple "${n_args[@]}" | tar -xf -  ;;
            *.tar.lz4)   lz4 -T0 -d -q -c $1 | tar -xf - ;;
            *.zst)       benchmarkZstdDecode "$1" ;;
            *.tar.xz)    tar xf "$1"      ;;
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    benchmarkTgzTar xzf "$1" ;;
            *.tgz)       benchmarkTgzTar xzf "$1" ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar e "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       benchmarkTgzTar xzf "$1" ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.xz)        xz -d "$1"       ;;
            *.7z)        7z x "$1"        ;;
            *.lz4)       unlz4 "$1"       ;;
            *.lzma)      tar --lzma -xvf "$1" ;;
            *.lz4a)      unlz4a "$1"        ;;
            *)           echo "'$1' cannot be extracted via extract()" ; return 1 ;;
        esac
    else
        echo "'$1' is not a valid file"
        return 1
    fi
}

function nanoTimeElapsed() {
    # Only load zsh datetime module if running in Zsh
    if [[ -n "$ZSH_VERSION" ]]; then
        zmodload zsh/datetime
        local start_time end_time elapsed
        # 擷取開始時間（秒.微秒浮點數） / Capture start time (Seconds.Microseconds float)
        start_time=$EPOCHREALTIME
        # 執行目標命令 / Execute target command
        "$@"
        local rc=$?
        end_time=$EPOCHREALTIME
    else
        # Fallback for Bash: use date command instead
        local start_time end_time
        start_time=$(date +%s%N 2>/dev/null || date +%s)
        # 執行目標命令 / Execute target command
        "$@"
        local rc=$?
        end_time=$(date +%s%N 2>/dev/null || date +%s)
    fi
    
    # 計算時間差並轉換為奈秒 (1 秒 = 1,000,000,000 奈秒)
    # 使用 awk 處理浮點數運算以確保跨平台精確度
    # Calculate time difference and convert to nanoseconds (1 sec = 1,000,000,000 ns)
    # Use awk for floating-point math to ensure cross-platform precision
    if [[ -n "$ZSH_VERSION" ]]; then
        # Zsh: use EPOCHREALTIME (floating point seconds)
        elapsed_ns=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { printf "%010.0f", (end - start) * 1000000000 }')
    else
        # Bash: use nanosecond timestamps directly
        elapsed_ns=$((end_time - start_time))
    fi
    echo "==> Process $@ took: ${elapsed_ns} 奈秒/nanoseconds"
    return "$rc"
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

# R47 TGZ backend gate: -swift_tar mode exports LZFSE_REQUIRE_NATIVE_ZLIB=1
# and SWIFT_TAR_BIN. Outside that mode, keep the existing PATH-resolved tar.
# R47 TGZ 後端守門：-swift_tar 模式會匯出上述變數；未啟用時
# 維持原本由 PATH 解析 tar 的行為。
function benchmarkTgzTar() {
    if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
        if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
            echo "[Error] -swift_tar native zlib mode requires executable SWIFT_TAR_BIN." >&2
            return 1
        fi
        "$SWIFT_TAR_BIN" "$@"
    else
        tar "$@"
    fi
}

function benchmarkZstdDecode() {   # $1 = archive
    if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
        if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
            echo "[Error] -swift_tar native zstd mode requires executable SWIFT_TAR_BIN." >&2
            return 1
        fi
        # swift_tar detects zstd by magic and untars in the same process, so no
        # pipe and no second binary. / swift_tar 依 magic 偵測 zstd 並於同一行程
        # 內解 tar，因此不需管線、也不需第二個 binary。
        "$SWIFT_TAR_BIN" -x -f "$1"
    else
        zstd -d -c "$1" | tar -xf -
    fi
}

## This script helps to creat a tar.xz for a folder.
function getar() {
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    XZ_OPT=-e9 benchmarkTgzTar czf "$1".tgz -C "$tar_parent" "$tar_leaf"
    du -sh "$1"
    du -sh "$1.tgz"
}

function lzfseX() {
    # 如果參數 $1 為空則提示並退出
    if [[ -z "$1" ]]; then
        echo "使用方法: lzfseX <檔案或目錄> [other3|apple|bvx3|lazy2|optimal|optimal3|bvx3_lazy2|bvx3_optimal|other3_optimal3] [run|probe]"
        return 1
    fi
    if [[ ! -e "$1" ]]; then
        echo "[Error] lzfseX target not found: $1"
        return 1
    fi

    # 設置預設值為 'other3' (若 $2 為空)；第三參數 mode：run（預設）或 probe（僅量測記憶體峰值）
    local algo="${2:-other3}"
    local mode="${3:-run}"
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."

    # 根據演算法設定副檔名（lazy2/optimal 為 bvx3 的解析器旗標）
    local extension="lzfse.other3"
    local flags=""
    local n_args=()
    if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
        n_args=(-n "$LZFSE_BENCH_N")
    fi
    case "$algo" in
        apple)    extension="lzfse.apple" ;;
        bvx3)     extension="lzfse.bvx3" ;;
        lazy2|bvx3_lazy2)    extension="lzfse.bvx3.lazy2";   algo="bvx3"; flags="-lazy2" ;;
        optimal|bvx3_optimal)  extension="lzfse.bvx3.optimal"; algo="bvx3"; flags="-optimal" ;;
        optimal3|other3_optimal3) extension="lzfse.other3.optimal3"; algo="other3"; flags="-optimal3" ;;
        other3)   extension="lzfse.other3" ;;
        *)        echo "[Error] unknown lzfseX algorithm: $algo"; return 1 ;;
    esac

    # 記憶體峰值量測模式（沿用上方 algo/flags 對應）：直接量「lzfse 編碼程序」的 peak RSS，
    # 不產生 benchmark 產物。lazy2/optimal 皆走 bvx3 平行編碼，用以實證「已讀未寫 ≤ maxTasks」
    # → 記憶體上界 ≈ maxTasks × chunkSize（見 OPTIMIZATION.md R19）。輸出寫 /dev/null 不佔磁碟。
    if [[ "$mode" == "probe" ]]; then
        local probe_label="encode ${1##*/} ${algo}${flags:+ }${flags}${LZFSE_BENCH_N:+ -n ${LZFSE_BENCH_N}}"
        echo "[Info] 記憶體峰值量測 (${probe_label}) / Encode peak-RSS probe:"
        if ! /usr/bin/time -l true 2>/dev/null; then
            echo "[MEM] ${probe_label}: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
            return 0
        fi
        tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "$probe_label" \
            lzfse -encode -si -o /dev/null -algo "$algo" ${=flags} "${n_args[@]}"
        return 0
    fi

    # 執行壓縮
    echo "執行中: tar -cf - -C $tar_parent $tar_leaf | lzfse -encode -si -o $1.$extension -algo $algo $flags ${n_args[*]}"
    tar -cf - -C "$tar_parent" "$tar_leaf" | lzfse -encode -si -o "$1.$extension" -algo "$algo" ${=flags} "${n_args[@]}"
    local rc=$?
    if [[ $rc -ne 0 || ! -f "$1.$extension" ]]; then
        echo "[Error] lzfseX failed to create $1.$extension"
        return 1
    fi
    
    # 顯示檔案大小（含精確 byte 數，供 benchmark 計算精確壓縮比）
    # Show sizes (incl. exact bytes so benchmarks can compute precise ratios)
    echo "--- 壓縮資訊 ---"
    du -sh "$1"
    du -sh "$1.$extension"
    echo "[SIZE] $1.$extension: $(stat -f%z "$1.$extension" 2>/dev/null || stat -c%s "$1.$extension") bytes"
}

function getzstd() {
   local tar_parent="${1:h}"
   local tar_leaf="${1:t}"
   [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
   # Encode must go through the same gate as decode. Otherwise native mode would
   # pair a system-tar archive with a swift_tar extraction, and the AppleDouble
   # entries bsdtar writes for extended attributes (com.apple.provenance is on
   # every file in both corpora) come back as literal `._` files instead of
   # being restored as attributes -- a different file count, a different amount
   # of write work, and a decode number that is not comparable.
   # encode 必須與 decode 走同一個閘門，否則 native 模式會變成「系統 tar 建檔、
   # swift_tar 解出」：bsdtar 為擴充屬性寫入的 AppleDouble 項目（兩份語料的每個
   # 檔案都帶有 com.apple.provenance）會被還原成實體的 `._` 檔案，而非還原為屬性
   # ——檔案數不同、寫入工作量不同，解碼數字也就失去可比性。
   if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
       if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
           echo "[Error] -swift_tar native zstd mode requires executable SWIFT_TAR_BIN." >&2
           return 1
       fi
       # Level 9 matches the external path's `zstd -9`, so the two rows differ only
       # by implementation, not by setting. swift_tar still compresses in
       # independent 4 MiB chunks (that is what makes it parallel), so its output
       # can be larger than a single external stream on highly redundant data --
       # a design trade-off to report, not a defect.
       # 等級 9 與外部路徑的 `zstd -9` 一致，使兩列只差在實作而非設定。swift_tar
       # 仍以獨立的 4 MiB 分塊壓縮（正是其得以並行的原因），故在高度冗餘的資料上
       # 其輸出可能大於單一外部串流——這是應如實回報的設計取捨，並非缺陷。
       "$SWIFT_TAR_BIN" -c --zstd --zstd-level 9 -f "$1.zst" -C "$tar_parent" "$tar_leaf"
   else
       tar -cf - -C "$tar_parent" "$tar_leaf" | zstd -9 -T0 -c > "$1.zst"
   fi
    # tar -I 'zstd -1' -cvf $1.zst $1
    du -sh "$1"
    du -sh "$1.zst"
}

function tlz4() {
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    tar -cf - -C "$tar_parent" "$tar_leaf" | lz4 -T0 -6 -q > "$1.tar.lz4"
    # tar --use-compress-program=lz4 -cf  $1.tar.lz4 $1
    du -sh "$1"
    du -sh "$1.tar.lz4" 
}

function diskcheck() {
    # 磁碟空間預檢（xbenchTest 峰值約 2 × 原始大小；建議保留 ≥20GB）
    # Disk space pre-check (xbenchTest peaks at ~2× raw size; recommend ≥20GB free)
    local avail_kb avail_gb
    avail_kb=$(df -k . | tail -1 | awk '{print $4}')
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < 20 )); then
        echo "[Warning] 磁碟可用空間僅 ${avail_gb}GB，建議 ≥20GB，否則解壓可能失敗！"
        echo "[Warning] Only ${avail_gb}GB free — recommend ≥20GB to avoid disk-full failures."
        return 1
    else
        echo "[Info] 磁碟可用空間充足：${avail_gb}GB / Sufficient disk space: ${avail_gb}GB"
        return 0
    fi

}

function benchStatus() {
    local status_file="${ROUND_STATUS_FILE:-round_status.txt}"
    echo "$@ $(date +%H:%M:%S)" >> "$status_file"
}

function benchAlgoName() {
    case "$1" in
        *.tgz)                echo "tgz" ;;
        *.zst)                echo "zstd" ;;
        *.tar.lz4)            echo "tar.lz4" ;;
        *.lzfse.other3.optimal3) echo "optimal3" ;;
        *.lzfse.other3)       echo "other3" ;;
        *.lzfse.apple)        echo "apple" ;;
        *.lzfse.bvx3.lazy2)   echo "lazy2" ;;
        *.lzfse.bvx3.optimal) echo "optimal" ;;
        *.lzfse.bvx3)         echo "bvx3" ;;
        *)                    echo "${1##*.}" ;;
    esac
}

function benchStatMode() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%a' "$1" 2>/dev/null
    else
        stat -f '%Lp' "$1" 2>/dev/null
    fi
}

function benchStatMtime() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%Y' "$1" 2>/dev/null
    else
        stat -f '%m' "$1" 2>/dev/null
    fi
}

function benchStatSize() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%s' "$1" 2>/dev/null
    else
        stat -f '%z' "$1" 2>/dev/null
    fi
}

function benchStatIdentity() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%d:%i:%h' "$1" 2>/dev/null
    else
        stat -f '%d:%i:%l' "$1" 2>/dev/null
    fi
}

function benchSha256() {
    local digest
    if command -v sha256sum > /dev/null 2>&1; then
        digest="$(sha256sum "$1")"
        echo "${digest%% *}"
    elif command -v shasum > /dev/null 2>&1; then
        digest="$(shasum -a 256 "$1")"
        echo "${digest%% *}"
    elif command -v openssl > /dev/null 2>&1; then
        digest="$(openssl dgst -sha256 "$1")"
        echo "${digest##* }"
    else
        echo "[Error] sha256sum, shasum, or openssl is required for manifest hashing." >&2
        return 1
    fi
}

function benchManifestLine() {
    local root="$1"
    local rel="$2"
    local entry_path="$root"
    [[ "$rel" != "." ]] && entry_path="$root/$rel"

    local file_mode file_mtime
    file_mode="$(benchStatMode "$entry_path")"
    file_mtime="$(benchStatMtime "$entry_path")"

    if [[ -L "$entry_path" ]]; then
        local target
        target="$(readlink "$entry_path")"
        printf 'L\t%s\tmode=%s\tmtime=%s\ttarget=%s\n' "$rel" "$file_mode" "$file_mtime" "$target"
    elif [[ -d "$entry_path" ]]; then
        printf 'D\t%s\tmode=%s\tmtime=%s\n' "$rel" "$file_mode" "$file_mtime"
    elif [[ -f "$entry_path" ]]; then
        local size sha identity nlink hardlink
        size="$(benchStatSize "$entry_path")"
        sha="$(benchSha256 "$entry_path")"
        identity="$(benchStatIdentity "$entry_path")"
        nlink="${identity##*:}"
        hardlink="none"
        if [[ "$nlink" == <-> && "$nlink" -gt 1 ]]; then
            if [[ -n "${bench_manifest_seen_hardlinks[$identity]:-}" ]]; then
                hardlink="${bench_manifest_seen_hardlinks[$identity]}"
            else
                bench_manifest_seen_hardlinks[$identity]="$rel"
                hardlink="self"
            fi
        fi
        printf 'F\t%s\tmode=%s\tmtime=%s\tsize=%s\tsha256=%s\thardlink=%s\n' "$rel" "$file_mode" "$file_mtime" "$size" "$sha" "$hardlink"
    else
        printf 'O\t%s\tmode=%s\tmtime=%s\n' "$rel" "$file_mode" "$file_mtime"
    fi
}

function benchManifestRoot() {
    local root="$1"
    local out="$2"
    if [[ ! -d "$root" ]]; then
        echo "[Error] manifest root not found: $root" >&2
        return 1
    fi

    mkdir -p "${out:h}" > /dev/null 2>&1
    typeset -gA bench_manifest_seen_hardlinks
    bench_manifest_seen_hardlinks=()

    {
        benchManifestLine "$root" "."
        local rel
        local entries=()
        (
            cd "$root" || exit 1
            entries=(**/*(DN))
            printf '%s\n' "${entries[@]}"
        ) | LC_ALL=C sort -u | while IFS= read -r rel; do
            [[ -n "$rel" ]] && benchManifestLine "$root" "$rel"
        done
    } > "$out"
}

function benchCompareTreeManifest() {
    local expected_root="$1"
    local actual_root="$2"
    local label="$3"
    local reusable_expected_manifest="${4:-}"
    local manifest_dir="${LZ4BENCH_LOG_DIR:-lz4bench_log}/tree_manifest"
    local expected_manifest="$manifest_dir/${label}.tgz-manifest.txt"
    local actual_manifest="$manifest_dir/${label}.actual-manifest.txt"
    local diff_file="$manifest_dir/${label}.manifest-diff.txt"

    mkdir -p "$manifest_dir" > /dev/null 2>&1
    if [[ -n "$reusable_expected_manifest" && -f "$reusable_expected_manifest" ]]; then
        expected_manifest="$reusable_expected_manifest"
    else
        benchManifestRoot "$expected_root" "$expected_manifest" || return 1
    fi
    benchManifestRoot "$actual_root" "$actual_manifest" || return 1

    if diff -u "$expected_manifest" "$actual_manifest" > "$diff_file"; then
        rm -f "$diff_file"
        return 0
    fi

    echo "[Info] manifest expected: $expected_manifest"
    echo "[Info] manifest actual:   $actual_manifest"
    echo "[Info] manifest diff:     $diff_file"
    return 1
}

# ------------------------------------------------------------------------------
# FUNCTION: memProbe()
# DESCRIPTION: 以 /usr/bin/time -l（macOS）量測「單一程序」的 peak RSS。
#   關鍵：time -l 必須「直接」前綴目標程序（如 lzfse），不可包成 `sh -c "管線"`，
#   否則 wait4 取得的是 shell 的 rusage（僅數 MB），而非 lzfse 真正的常駐記憶體。
#   $1 = 標籤；其餘參數 = 要量測的命令（直接 exec，不經 shell）。
#   stdin 由呼叫端以管線/重導提供（如 `tar -cf - dir | memProbe ... lzfse -encode -si ...`）。
# ------------------------------------------------------------------------------
function memProbe() {
    local label="$1"; shift
    if ! /usr/bin/time -l true 2>/dev/null; then
        echo "[MEM] ${label}: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
        return 0
    fi
    /usr/bin/time -l "$@" 2>&1 \
        | awk -v l="$label" '/maximum resident set size/ {printf "[MEM] %s peak RSS: %.1f MB\n", l, $1/1048576}'
}

function archiveMemProbe() {
    local target="$1"
    local fmt="$2"
    local folder="${target##*/}"
    if [[ -z "$target" || -z "$fmt" ]]; then
        echo "使用方法: archiveMemProbe <target> [tgz|zst|zstd|tar.lz4]"
        return 1
    fi

    case "$fmt" in
        tgz)
            echo "[Info] 記憶體峰值量測 (encode ${folder} tgz) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} tgz: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
                [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zlib probe requires SWIFT_TAR_BIN." >&2; return 1; }
                memProbe "encode ${folder} tgz" "$SWIFT_TAR_BIN" czf /dev/null -C "$tar_parent" "$tar_leaf"
            else
                memProbe "encode ${folder} tgz" tar czf /dev/null -C "$tar_parent" "$tar_leaf"
            fi
            ;;
        zst|zstd)
            echo "[Info] 記憶體峰值量測 (encode ${folder} zstd) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} zstd: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "encode ${folder} zstd" zstd -9 -T0 -q -f -o /dev/null
            ;;
        tar.lz4)
            echo "[Info] 記憶體峰值量測 (encode ${folder} tar.lz4) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} tar.lz4: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "encode ${folder} tar.lz4" lz4 -T0 -6 -q -f - /dev/null
            ;;
        *)
            echo "[Error] unknown archiveMemProbe format: $fmt"
            return 1
            ;;
    esac
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

    # 磁碟空間預檢（lazy2/optimal 解壓在磁碟壓力下數據嚴重失真，見 OPTIMIZATION.md R11/R12）
    # Disk pre-check (lazy2/optimal decompression numbers degrade badly under disk pressure)
    diskcheck "$1" || return 1

    if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
        echo "[Info] Fixed LZFSE -n for this round: -n ${LZFSE_BENCH_N}"
    fi
    local status_suffix="${LZFSE_BENCH_SUFFIX:-}"
    benchStatus "RUNNING_LZ4BENCH ${1}${status_suffix}"

    # Warm-cache：預讀整個資料集進 OS page cache，消除「第一個格式 cold-cache、
    # 後續格式 warm-cache」造成的壓縮計時偏差（見 OPTIMIZATION.md R15/R16 cold-cache 註）
    # Warm-cache: pre-read the whole dataset so every compression format is timed
    # under the same warm-cache condition (removes first-format cold-cache skew).
    echo $'\n[Info] Warm-cache 預讀資料集 / Pre-reading dataset to warm OS cache...'
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    tar -cf - -C "$tar_parent" "$tar_leaf" > /dev/null 2>&1

    echo $'[Info] 開始執行 tgz, lzfse, tlz4, zstd 基準測試...\n'

    # --------------------------------------------------------------------------
    # 1. 壓縮測試
    # --------------------------------------------------------------------------
    echo $'\n[Info] 測試 getar 壓縮 / Testing getar compression:'
    nanoTimeElapsed getar $1
    local encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.tgz" ]] && benchStatus "ENCODED ${1}${status_suffix} tgz" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} tgz ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX other3 壓縮 / Testing lzfseX other3 compression:'
    nanoTimeElapsed lzfseX $1 other3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.other3" ]] && benchStatus "ENCODED ${1}${status_suffix} other3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} other3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX other3_optimal3 壓縮 / Testing lzfseX other3_optimal3 compression:'
    nanoTimeElapsed lzfseX $1 optimal3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.other3.optimal3" ]] && benchStatus "ENCODED ${1}${status_suffix} optimal3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} optimal3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3_lazy2 壓縮 / Testing lzfseX bvx3_lazy2 compression:'
    nanoTimeElapsed lzfseX $1 lazy2
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3.lazy2" ]] && benchStatus "ENCODED ${1}${status_suffix} lazy2" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} lazy2 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3_optimal 壓縮 / Testing lzfseX bvx3_optimal compression:'
    nanoTimeElapsed lzfseX $1 optimal
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3.optimal" ]] && benchStatus "ENCODED ${1}${status_suffix} optimal" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} optimal ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3 壓縮 / Testing lzfseX bvx3 compression:'
    nanoTimeElapsed lzfseX $1 bvx3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3" ]] && benchStatus "ENCODED ${1}${status_suffix} bvx3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} bvx3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX apple 壓縮 / Testing lzfseX apple compression:'
    nanoTimeElapsed lzfseX $1 apple
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.apple" ]] && benchStatus "ENCODED ${1}${status_suffix} apple" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} apple ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 tlz4  壓縮 / Testing tlz4 compression:'
    nanoTimeElapsed tlz4 $1
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.tar.lz4" ]] && benchStatus "ENCODED ${1}${status_suffix} tar.lz4" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} tar.lz4 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 zstd  壓縮 / Testing zstd compression:'
    nanoTimeElapsed getzstd $1
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.zst" ]] && benchStatus "ENCODED ${1}${status_suffix} zstd" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} zstd ${encode_rc}"; return 1; }

    # --------------------------------------------------------------------------
    # 1b. 壓縮產物精確大小摘要（lazy2/optimal 等的壓縮比以此為準）
    #     Exact compressed sizes summary (authoritative for ratio calculation)
    # --------------------------------------------------------------------------
    echo $'\n[Info] 壓縮產物精確大小 / Exact compressed sizes:'
    echo "[SIZE] $1 (raw): $(du -sk "$1" | awk '{print $1}') KB"
    local size_targets=("$1.tgz" "$1.lzfse.other3" "$1.lzfse.other3.optimal3" "$1.lzfse.bvx3.lazy2" "$1.lzfse.bvx3.optimal" "$1.lzfse.bvx3" "$1.lzfse.apple" "$1.tar.lz4" "$1.zst")
    local missing_artifacts=0
    for f in "${size_targets[@]}"; do
        if [[ -f "$f" ]]; then
            echo "[SIZE] $f: $(stat -f%z "$f" 2>/dev/null || stat -c%s "$f") bytes"
        else
            echo "[SIZE] $f: MISSING（壓縮產物不存在 / artifact not found）"
            missing_artifacts=1
        fi
    done
    if (( missing_artifacts )); then
        echo "[Error] one or more compression artifacts are missing; abort benchmark."
        return 1
    fi

    echo $'\n=================================================='
    echo $'[Info] 開始評測解壓縮速度 / Benchmarking decompression score:'
    echo $'=================================================='

    # --------------------------------------------------------------------------
    # 2. 解壓縮測試 + 即時一致性驗證
    #    每個格式解壓後立即核對 tgz 基準並清理，避免 xbenchTest 峰值過大導致磁碟爆滿
    #    Decompression + inline consistency check: each format is verified then
    #    immediately removed, keeping peak xbenchTest disk usage to ~2× raw size.
    # --------------------------------------------------------------------------
    local extract_targets=("$1.tgz" "$1.lzfse.other3" "$1.lzfse.other3.optimal3" "$1.lzfse.bvx3.lazy2" "$1.lzfse.bvx3.optimal" "$1.lzfse.bvx3" "$1.lzfse.apple" "$1.tar.lz4" "$1.zst")
    local base_dir="./xbenchTest/tgz"   # tgz 保留到最後作為比對基準
    local is_first=true
    local manifest_label_base="${1}${status_suffix}"
    manifest_label_base="${manifest_label_base//\//_}"
    local manifest_dir="${LZ4BENCH_LOG_DIR:-lz4bench_log}/tree_manifest"
    local base_manifest="$manifest_dir/${manifest_label_base}.tgz-baseline-manifest.txt"

    for target in "${extract_targets[@]}"; do
        local test_dir="./xbenchTest/${target##*.}"
        local target_algo
        target_algo="$(benchAlgoName "$target")"
        mkdir -p "$test_dir" > /dev/null 2>&1
        if ! mv "$target" "$test_dir" > /dev/null 2>&1; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} move_artifact"
            echo "[Error] failed to move $target into $test_dir"
            return 1
        fi

        echo $'\n[Info] 測試 '$target' 解壓:'
        (
            cd "$test_dir" > /dev/null 2>&1
            rm -rf "$1" > /dev/null 2>&1
            nanoTimeElapsed extract "$target"
        )
        local extract_rc=$?
        if ! mv "$test_dir/$target" "$target" > /dev/null 2>&1; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} restore_artifact"
            echo "[Error] failed to restore $target from $test_dir"
            return 1
        fi
        if [[ $extract_rc -ne 0 ]]; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} ${extract_rc}"
            echo "[Error] $target 解壓失敗 / decompression failed"
            return "$extract_rc"
        fi
        benchStatus "DECODED ${1}${status_suffix} ${target_algo}"

        # 即時一致性核對 + 立即清理（tgz 基準保留到所有格式完成）
        # Inline consistency check + immediate cleanup (tgz base kept until end)
        if $is_first; then
            is_first=false   # tgz 作為基準，跳過自比對
            if benchManifestRoot "$base_dir/$1" "$base_manifest"; then
                benchStatus "COMPARE_BASE ${1}${status_suffix} tgz"
            else
                benchStatus "COMPARE_BASE_FAILED ${1}${status_suffix} tgz manifest"
                echo "[Error] failed to create tgz baseline tree manifest"
                return 1
            fi
        else
            local compare_label="${manifest_label_base}.${target_algo}"
            if benchCompareTreeManifest "$base_dir/$1" "$test_dir/$1" "$compare_label" "$base_manifest"; then
                echo "[Success] $target 解壓 tar 語意與 tgz 一致！"
                benchStatus "COMPARED_WITH_TGZ_OK ${1}${status_suffix} ${target_algo}"
            else
                echo "[Warning] $target 解壓 tar 語意與 tgz 不一致！"
                benchStatus "COMPARED_WITH_TGZ_FAILED ${1}${status_suffix} ${target_algo}"
                rm -rf "$test_dir"
                return 1
            fi
            rm -rf "$test_dir"   # 立即釋放此格式的解壓空間
        fi
    done

    # --------------------------------------------------------------------------
    # 3. 最終清理 / Final cleanup
    # --------------------------------------------------------------------------
    rm -rf "./xbenchTest"

    # --------------------------------------------------------------------------
    # 4. 記憶體峰值量測（選用，LZFSE_MEMPROBE=1）/ Peak-RSS probes (opt-in)
    #    必須放在壓縮與解壓 benchmark 後，避免 probe 改變 page-cache / memory pressure，
    #    污染正式解壓 MB/s。encode：直接量目標編碼程序；decode：用既有壓縮產物。
    # --------------------------------------------------------------------------
    if [[ "$LZFSE_MEMPROBE" == "1" ]]; then
        mkdir -p memprobeResults > /dev/null 2>&1
        echo $'\n[Info] 記憶體峰值量測 (tgz / zstd / tar.lz4 / other3 / optimal3 / apple / bvx3 / lazy2 / optimal，encode + decode) / Peak-RSS probes:'
        local probe_algo probe_file probe_artifact probe_suffix
        probe_suffix="${LZFSE_BENCH_SUFFIX:-}"
        for probe_algo in tgz zstd tar.lz4 other3 optimal3 apple bvx3 lazy2 optimal; do
            case "$probe_algo" in
                tgz)      probe_artifact="$1.tgz" ;;
                zstd)     probe_artifact="$1.zst" ;;
                tar.lz4)  probe_artifact="$1.tar.lz4" ;;
                other3)   probe_artifact="$1.lzfse.other3" ;;
                optimal3) probe_artifact="$1.lzfse.other3.optimal3" ;;
                apple)    probe_artifact="$1.lzfse.apple" ;;
                bvx3)     probe_artifact="$1.lzfse.bvx3" ;;
                lazy2)    probe_artifact="$1.lzfse.bvx3.lazy2" ;;
                optimal)  probe_artifact="$1.lzfse.bvx3.optimal" ;;
            esac
            probe_file="memprobeResults/${1}${probe_suffix}-${probe_algo}-memprobe.txt"
            benchStatus "RUNNING_MEMPROBE ${1}${status_suffix} ${probe_algo}"
            case "$probe_algo" in
                tgz|zstd|tar.lz4) archiveMemProbe "$1" "$probe_algo" > "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} encode"; return 1; } ;;
                *) lzfseX "$1" "$probe_algo" probe > "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} encode"; return 1; } ;;
            esac
            extract "$probe_artifact" probe >> "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} decode"; return 1; }
            benchStatus "MEMPROBE_DONE ${1}${status_suffix} ${probe_algo}"
        done
    fi

    benchStatus "LZ4BENCH_DONE ${1}${status_suffix}"
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
    # diskutil is macOS-only; on Windows this printed "command not found" on
    # every shell start. Guarded by presence rather than by platform so it also
    # stays quiet anywhere else diskutil is absent.
    # diskutil 僅存在於 macOS；在 Windows 上會使每次啟動 shell 都印出
    # "command not found"。以「指令是否存在」而非平台判斷，因此在其他沒有
    # diskutil 的環境同樣保持安靜。
    if (( $+commands[diskutil] )); then
        diskutil list | grep "RAMDisk" -B4 | grep "/dev" | awk '{print $1}' | tail -n +2 | xargs -I {} diskutil eject {}
    fi
    # claudeCodeEnv 2>&1 > /dev/null
    # antigravity support
    export PATH="/Users/raliclo/.local/bin:$PATH"
}

START_UP@END
source ~/.hf_token

# NOTE: `START_UP@END` finalizes environment injection: it sets conservative
# defaults (e.g., `MAKEJOBS`), applies `setcc`, and defines aliases used in
# interactive shells. It is safe to re-run but should avoid heavy side-effects.
