# 串口登录：先问终端尺寸并 stty，再让 byobu 启动。
#
# /etc/profile 末尾还有一段 Yocto 自带的 resize：它只等很短的时间，
# 回复经监视器绕一圈晚到，就会被当成键盘输入交给 shell（登录时出现
# sh: [8: command not found）。在 ttyPS0 上改用 /usr/local/bin/tty-size，
# 并把 FIRSTTIMESETUP 清掉，让那段 resize 不执行。
case "$(tty 2>/dev/null)" in
    /dev/tty[A-Za-z]*)
        if [ -z "${TMUX:-}" ] && [ -x /usr/local/bin/tty-size ]; then
            /usr/local/bin/tty-size
        fi
        FIRSTTIMESETUP=0
        ;;
esac
