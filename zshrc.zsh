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
