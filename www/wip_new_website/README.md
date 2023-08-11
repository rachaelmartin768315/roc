
# Getting Started

## Prerequisites

- Linux or MacOS operating system, Windows users can use linux through WSL.
- Install [git](https://chat.openai.com/share/71fb3ae6-80d7-478c-8a27-a36aaa5ba921)
- Install [nix](https://nixos.org/download.html)

## Building the website from scratch

```bash
git clone https://github.com/roc-lang/roc.git
cd roc
nix develop
./www/build.sh
# make the roc command available 
export PATH="$(pwd)/target/release/:$PATH"
cd www/wip_new_website
roc build.roc
```

Open http://0.0.0.0:8080/wip in your browser.

## After you've made a change

In the terminal where `roc build.roc` is running:
1. kill the server with Ctrl+C
2. run `roc build.roc`
3. refresh the page in your browser