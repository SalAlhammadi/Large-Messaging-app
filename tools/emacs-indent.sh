#!/bin/bash

FILES=$(git grep --name-only emacs-indent-begin src/)


for FILENAME in $FILES; do
    echo "==> Indenting $FILENAME..."
    emacs -batch $FILENAME \
       -f "erlang-mode" \
        --eval "(goto-char (point-min))" \
        --eval "(re-search-forward \"emacs-indent-begin\" nil t)" \
        --eval "(setq begin (line-beginning-position))" \
        --eval "(re-search-forward \"emacs-indent-end\" nil t)" \
        --eval "(setq end (line-beginning-position))" \
        --eval "(erlang-indent-region begin end)" \
        --eval "(goto-char (point-min))" \
        --eval "(re-search-forward \"emacs-untabify-begin\" nil t)" \
        --eval "(setq begin (line-beginning-position))" \
        --eval "(re-search-forward \"emacs-untabify-end\" nil t)" \
        --eval "(setq end (line-beginning-position))" \
        --eval "(erlang-indent-region begin end)" \
        --eval "(untabify begin end)" \
       -f "delete-trailing-whitespace" \
       -f "save-buffer"
done
