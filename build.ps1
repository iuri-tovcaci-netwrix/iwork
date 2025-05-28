#
# Need to install go compiler (to be in PATH) from https://go.dev/dl/
#

go mod init github.com/dunhamsteve/iwork
go mod tidy

Set-Location iwork2html
# Flags specify to strip symbols, making the binary smaller
go build -ldflags "-s -w"
