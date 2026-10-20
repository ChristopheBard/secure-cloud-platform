# Build en 2 étapes ("multi-stage") :
#   1. une image avec le compilateur Go fabrique le binaire
#   2. l'image finale ne contient QUE ce binaire, sur une base "distroless"
# Résultat : une image de quelques Mo, sans shell ni outils qu'un attaquant pourrait utiliser.

# Étape 1 : compilation
FROM golang:1.27-alpine AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod main.go ./
# CGO_ENABLED=0 : binaire 100 % statique, il n'a besoin d'aucune bibliothèque système.
# -X main.version : injecte le SHA du commit dans le binaire.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

# Étape 2 : image finale
# distroless/static = juste les certificats racines et les fuseaux horaires, rien d'autre.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
# Utilisateur non-root (UID 65532), le même que dans la task definition ECS.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
