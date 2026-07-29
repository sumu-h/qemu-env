FROM docker.cnb.cool/sumu.k/docker-learning/ubuntu-22.04

# install vscode and extension
RUN code-server --install-extension mads-hartmann.bash-ide-vscode &&\
    code-server --install-extension llvm-vs-code-extensions.vscode-clangd &&\
    code-server --install-extension xaver.clang-format &&\
    code-server --install-extension ms-vscode.hexeditor 

# 安装 clangd 
ADD https://cnb.cool/sumu.k/my-linux/-/git/raw/main/Embedded/clangd.sh /script/clangd.sh

RUN cd /script &&\
    chmod +x *.sh && \
    bash ./clangd.sh &&\
    cd / && rm -rf /script