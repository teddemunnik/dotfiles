; Package system initialisation
(add-to-list 'load-path "~/.emacs.d/lib/")
(require 'package)
(eval-when-compile (require 'use-package))
(add-to-list 'package-archives `("melpa" . "http://melpa.org/packages/"))
(package-initialize)

; UI Customisation 
(use-package monokai-theme
  :ensure t
  :init (load-theme 'monokai t))

(set-face-attribute 'default nil :family "Source Code Pro Regular")
(menu-bar-mode -1) ; No menu bar in UI emacs
(tool-bar-mode -1) ; No toolbar in UI emacs
(scroll-bar-mode -1) ; No scrollbar in UI emacs

; Evil for dat vim emulation
(use-package evil
  :init
  (evil-mode 1))

; Combination of helm/projectile to get Ctrl+P find files in project
(use-package helm
  :ensure t)
(use-package projectile
  :ensure t
  :config
  (use-package helm-projectile
    :ensure t
    :init
    (define-key evil-normal-state-map (kbd "C-p") 'helm-projectile-find-file)))
  :init
  (projectile-global-mode)
