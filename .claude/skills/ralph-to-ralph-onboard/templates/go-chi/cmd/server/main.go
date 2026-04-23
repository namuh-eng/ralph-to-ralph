package main

import (
	"log"
	"net/http"

	ralphhttp "github.com/example/ralph-go-chi-template/internal/http"
)

func main() {
	log.Fatal(http.ListenAndServe(":3015", ralphhttp.NewRouter()))
}
