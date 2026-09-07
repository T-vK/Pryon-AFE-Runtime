package main

import (
	"os"
	"os/exec"
)

func main() {
	afePath := os.Getenv("AFE")
	if afePath == "" {
		afePath = "./build/afe"
	}
	pryonPath := os.Getenv("PRYON")
	if pryonPath == "" {
		pryonPath = "./build/pryon"
	}
	afe := exec.Command(afePath)
	pryonArgs := []string{}
	if modelDir := os.Getenv("PRYON_MODEL_DIR"); modelDir != "" {
		pryonArgs = []string{"--model-dir", modelDir}
	}
	pryon := exec.Command(pryonPath, pryonArgs...)

	afe.Stdin = os.Stdin
	pryon.Stdout = os.Stdout
	pryon.Stderr = os.Stderr

	afeOut, err := afe.StdoutPipe()
	if err != nil {
		panic(err)
	}
	pryon.Stdin = afeOut

	if err := afe.Start(); err != nil {
		panic(err)
	}
	if err := pryon.Start(); err != nil {
		panic(err)
	}
	if err := afe.Wait(); err != nil {
		panic(err)
	}
	if err := pryon.Wait(); err != nil {
		panic(err)
	}
}
