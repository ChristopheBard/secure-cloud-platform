// Application de démo : une page "Hello World" qui affiche la version déployée
// et l'AZ du conteneur qui a répondu. En rafraîchissant la page, on voit l'ALB
// répartir le trafic entre les 2 zones.
//
// Écrite en Go pour produire un binaire unique, sans dépendance :
// l'image finale ne contient que ce binaire (pas de shell, pas de gestionnaire de paquets),
// donc quasiment rien à scanner ou à exploiter.
package main

import (
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"
)

// Remplacée au build par le SHA du commit (voir Dockerfile).
var version = "dev"

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Secure Cloud Platform</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 40rem; color: #232F3E; }
  code { background: #f2f3f3; padding: .1rem .4rem; border-radius: 4px; }
</style></head>
<body>
  <h1>Hello from the Secure Cloud Platform</h1>
  <p>Version: <code>{{.Version}}</code></p>
  <p>Served by a task in Availability Zone: <code>{{.AZ}}</code></p>
</body>
</html>`))

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	az := availabilityZone()
	log.Printf("starting version=%s az=%s port=%s", version, az, port)

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		page.Execute(w, map[string]string{"Version": version, "AZ": az})
	})

	// Timeouts explicites : un client lent ne peut pas bloquer le serveur indéfiniment.
	server := &http.Server{
		Addr:              ":" + port,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

// Lit l'AZ via l'endpoint de métadonnées qu'ECS expose à chaque conteneur.
// En local (pas sur ECS), cette variable n'existe pas : on renvoie "local".
func availabilityZone() string {
	uri := os.Getenv("ECS_CONTAINER_METADATA_URI_V4")
	if uri == "" {
		return "local"
	}

	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(uri + "/task")
	if err != nil {
		return "unknown"
	}
	defer resp.Body.Close()

	var task struct {
		AvailabilityZone string `json:"AvailabilityZone"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&task); err != nil {
		return "unknown"
	}
	return task.AvailabilityZone
}
