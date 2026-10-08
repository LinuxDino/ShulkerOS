# Shulker OS login shell setup (installed as /etc/profile.d/shulker.sh; refreshed at every boot).
# Edit /etc/shulker/profile.local for your own additions: this file is replaced on update.

# a copy on the disk (/opt/shulker, kept current by `shulker update`) wins over the data pack's
for d in /opt/shulker /mnt/builtin/shulker; do
	if [ -f "$d/lib/shulker/util.lua" ]; then SHULKER_HOME="$d"; break; fi
done
export SHULKER_HOME

case ":$PATH:" in *":$SHULKER_HOME/bin:"*) ;; *) PATH="$SHULKER_HOME/bin:$PATH" ;; esac
case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="/usr/local/bin:$PATH" ;; esac
case ":$PATH:" in *":/mnt/builtin/bin:"*) ;; *) [ -d /mnt/builtin/bin ] && PATH="$PATH:/mnt/builtin/bin" ;; esac
export PATH

export EDITOR=nano PAGER=less LESS=-R
export SHULKER_THEME="${SHULKER_THEME:-shulker}"

# the "shulker" prompt: purple user@host, lavender path
if [ "$SHULKER_THEME" = "plain" ]; then
	PS1='\u@\h:\w\$ '
elif [ "$SHULKER_THEME" = "ender" ]; then
	PS1='\[\033[36m\]\u@\h\[\033[0m\]:\[\033[96m\]\w\[\033[0m\]\$ '
else
	PS1='\[\033[35m\]\u@\h\[\033[0m\]:\[\033[95m\]\w\[\033[0m\]\$ '
fi
export PS1

alias ls='ls --color=auto'
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias df='df -h'
alias du='du -h'
alias grep='grep --color=auto'
alias crontab='crontab -c /etc/shulker/crontabs'
alias tasks='task list'
alias todo='task'
alias update='shulker update'
alias neofetch='shulkerfetch'
alias ask='claude -p'

[ -r /etc/shulker/profile.local ] && . /etc/shulker/profile.local

# first login: the setup wizard (skippable; `shulker setup` runs it again)
if [ -t 0 ] && [ -t 1 ] && [ ! -f /etc/shulker/setup.conf ] && [ "$(id -u)" = 0 ] && [ -x "$SHULKER_HOME/bin/shulker-setup" ]; then
	"$SHULKER_HOME/bin/shulker-setup"
	[ -f /etc/hostname ] && hostname -F /etc/hostname 2>/dev/null
fi
