# Image de l'application Tasky (todo list en Go qui stocke ses données dans MongoDB).
# Source d'origine : github.com/jeffthorne/tasky, image reconstruite ici avec des dépendances à jour.
#
# Build en 2 étapes ("multi-stage") :
#   1. une image avec le compilateur Go fabrique le binaire
#   2. l'image finale ne contient que le binaire, les pages web et le fichier wizexercise.txt

# Étape 1 : compilation
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 : binaire 100 % statique, il n'a besoin d'aucune bibliothèque système.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tasky .

# Étape 2 : image finale
# Alpine (et non distroless) : on garde un shell pour pouvoir prouver en démo,
# avec kubectl exec, que wizexercise.txt est bien présent dans le conteneur.
FROM alpine:3.23
# Applique les correctifs de sécurité publiés depuis la sortie de l'image de base.
RUN apk upgrade --no-cache && adduser -D -u 10001 tasky
WORKDIR /app
COPY --from=build /out/tasky ./tasky
COPY assets ./assets
# Exigence de l'exercice : un fichier wizexercise.txt qui contient mon nom, copié au build.
COPY wizexercise.txt ./wizexercise.txt
# Utilisateur non-root.
USER 10001
EXPOSE 8080
ENTRYPOINT ["/app/tasky"]
