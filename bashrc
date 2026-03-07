# space-needle shared bashrc — sourced by hsimah and adminhabl
# Source from ~/.bashrc:  source /srv/space-needle/bashrc

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# ── Colors ─────────────────────────────────────────────────────────────────────
export CLICOLOR=1
export LS_COLORS='di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=1;31:sg=1;31:tw=1;34:ow=1;34'

alias ls='ls --color=auto'
alias ll='ls -lAh'
alias grep='grep --color=auto'
alias diff='diff --color=auto'

# ── Key bindings ───────────────────────────────────────────────────────────────
# Ctrl+Backspace — delete word backward
bind '"\C-h": backward-kill-word' 2>/dev/null
# Ctrl+Delete — delete word forward
bind '"\e[3;5~": kill-word' 2>/dev/null

# ── Git prompt helper ─────────────────────────────────────────────────────────
__git_prompt() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  local hash
  hash=$(git rev-parse --short HEAD 2>/dev/null)
  echo " (${branch}@${hash})"
}

# ── Prompt ─────────────────────────────────────────────────────────────────────
# user@host:~/dir (branch@hash)$
#   green user for hsimah, red for adminhabl (root-capable)
__set_prompt() {
  local reset='\[\e[0m\]'
  local bold='\[\e[1m\]'
  local green='\[\e[1;32m\]'
  local red='\[\e[1;31m\]'
  local blue='\[\e[1;34m\]'
  local yellow='\[\e[1;33m\]'

  local user_color="$green"
  if [[ "$USER" == "adminhabl" ]]; then
    user_color="$red"
  fi

  PS1="${user_color}\u${reset}@${bold}\h${reset}:${blue}\w${reset}${yellow}\$(__git_prompt)${reset}\$ "
}
__set_prompt
unset -f __set_prompt

# ── History ────────────────────────────────────────────────────────────────────
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend

# ── Shell options ──────────────────────────────────────────────────────────────
shopt -s checkwinsize
shopt -s cdspell
shopt -s dirspell 2>/dev/null

# ── Bash completion ──────────────────────────────────────────────────────────
if ! shopt -oq posix; then
  if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
  elif [[ -f /etc/bash_completion ]]; then
    source /etc/bash_completion
  fi
fi

# ── Aliases ────────────────────────────────────────────────────────────────────
alias space-needle-ctl='/srv/space-needle/space-needle-ctl'
alias adminhabl='su - adminhabl'
