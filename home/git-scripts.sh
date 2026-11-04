unalias gco 2>/dev/null
unalias gb  2>/dev/null
unalias gbd 2>/dev/null
unalias gbD 2>/dev/null
unalias gcp 2>/dev/null
unalias grbi 2>/dev/null
unalias gsu 2>/dev/null

function get_branch() {
    git branch | fzf-tmux --ansi -1 $@ | sed 's/^[*+]\?\s*//'
}

function gb() {
    if [ $# -eq 0 ]; then
        get_branch
    else
        git branch $@
    fi
        
}

function gbd() {
    branch_names=$(get_branch)
    if [[ $branch_name ]]; then
        git branch --delete $branch_name
    fi
}

function gbD() {
    branch_names=$(get_branch)
    if [[ $branch_names ]]; then
        git branch --delete --force $branch_names
    fi
}

function gco() {
    cmd=""
    if [ $# -eq 0 ]; then
        branch_name=$(get_branch --no-multi)
        if [ -n "$branch_name" ]; then
            cmd="git checkout $branch_name"
        fi
    else
        cmd="git checkout $@"
    fi
    if [ -n "$cmd" ]; then
        cmd="$cmd && git submodule update --init --recursive"
    fi
    eval $cmd
}

function gcp() {
    if [ $# -eq 0 ]; then
        branch_name=$(get_branch --no-multi)
        commit_list=$(git log --pretty=format:"%h %s" $branch_name | fzf-tmux --multi --ansi --preview 'git show --pretty=short --name-only {1}' | cut -d' ' -f1)
        commit_number=$(echo $commit_list | wc -l)
        if [ $commit_number -eq 1 ]; then
            git cherry-pick $commit_list
        elif [ $commit_number -gt 1 ]; then
            first_commit=$(echo $commit_list | tail -n1)
            last_commit=$(echo $commit_list | head -n1)
            git cherry-pick ${first_commit}^..${last_commit}
        fi
    else
        git cherry-pick $@
    fi
}

# function gd() {
#     if [ $# -eq 0 ]; then
#         commit_hash=$(git log --pretty=format:"%H" | fzf-tmux --ansi --preview 'git show --pretty=short --name-only {}')
#         #commit_hash=${commit_hash//$'\n'/ } # example of bash variable expansion, will replace newlines with spaces
#         # note: the above is not needed when using the sh_word_split and the for loop but I am leaving it for example of bash variable expansion
#         unset commit_hash_rev
#         for hash (${(f)commit_hash})
#         do
#             commit_hash_rev="$hash $commit_hash_rev"
#         done
#         if [ ! -z $commit_hash_rev ]; then
#             cmd="git diff $commit_hash_rev"
#             eval $cmd
#         fi
#     else
#         git diff $@
#     fi
# }

function grbi() {
    commit_hash=$(git log --pretty=format:"%h %s" | fzf-tmux --ansi --preview 'git show --pretty=short --abbrev-commit --name-only {1}' | cut -d' ' -f1)
    if [ ! -z $commit_hash ]; then
        git rebase -i $commit_hash
    fi
}

alias gsu="git submodule update --init --recursive"
alias gst="git status"
