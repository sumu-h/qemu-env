#!/bin/bash

IMAGE_NAME="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/qemu-env"

show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -b       构建镜像"
    echo "  -p       推送镜像"
    echo "  -r       运行镜像"
    echo "  -c c|i   清除所有容器(c)或镜像(img)"
    echo "  -a       执行所有操作 (构建+推送+运行)"
    echo "  -h       显示帮助信息"
}

build_image() {
    echo "=========================================="
    echo "构建镜像: $IMAGE_NAME"
    echo "=========================================="
    # docker build --no-cache -t "$IMAGE_NAME" .
    docker build -f "$(dirname "$0")/Dockerfile" -t "$IMAGE_NAME" "$(dirname "$0")/../.."
}

push_image() {
    echo "=========================================="
    echo "推送镜像: $IMAGE_NAME"
    echo "=========================================="
    docker push "$IMAGE_NAME"
}

run_image() {
    echo "=========================================="
    echo "运行镜像: $IMAGE_NAME"
    echo "=========================================="
    # 容器启动后直接进入了sumu用户，运行sudo命令会报错，这里需要加上--security-opt选项
    # true	禁止进程获取新权限（sudo、setuid 程序失效）
    # false	允许进程获取新权限（sudo 正常工作）
    # docker run -it --rm --security-opt=no-new-privileges:false "$IMAGE_NAME" bash
    docker run -it --rm -p 8000:8000 --entrypoint "code-server" -d "$IMAGE_NAME" --bind-addr=0.0.0.0:8000 --auth=none
}

clean() {
    local clean_type="$1"
    case "$clean_type" in
        c|containers)
            echo "=========================================="
            echo "清除所有容器"
            echo "=========================================="
            docker ps -aq | xargs -r docker stop
            docker ps -aq | xargs -r docker rm
            echo "所有容器已清除"
            ;;
        i|images)
            echo "=========================================="
            echo "清除所有镜像"
            echo "=========================================="
            docker images -aq | xargs -r docker rmi -f
            echo "所有镜像已清除"
            ;;
        *)
            echo "无效参数: $clean_type"
            echo "用法: -c c (清除容器) 或 -c img (清除镜像)"
            exit 1
            ;;
    esac
}

main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi

    while getopts "bprc:ah" opt; do
        case $opt in
            b)
                build_image
                ;;
            p)
                push_image
                ;;
            r)
                run_image
                ;;
            c)
                clean "$OPTARG"
                ;;
            a)
                build_image && push_image && run_image
                ;;
            h)
                show_help
                ;;
            \?)
                echo "无效选项: -$OPTARG" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

main "$@"
