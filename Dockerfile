# Images de build : outils complets, jamais livrées
# Node 20 : dernière version LTS supportée par Angular 17
FROM node:20-alpine AS front-build

WORKDIR /src

# Dépendances d'abord : couche mise en cache tant que package*.json ne change pas
COPY ./front/package.json ./front/package-lock.json ./
RUN npm ci

COPY ./front ./
RUN npx ng build --configuration production

FROM gradle:8.7-jdk17-alpine AS back-build

WORKDIR /src

COPY ./back ./

# Gradle 8.7 est fourni par l'image (même version que le wrapper) : pas de téléchargement.
# Les tests sont exécutés par la CI : ici on ne produit que le JAR exécutable.
RUN gradle bootJar --no-daemon

# Images d'exécution : officielles, minimales (Alpine), utilisateur non-root
FROM caddy:2.8-alpine AS front

COPY misc/docker/Caddyfile /etc/caddy/Caddyfile
COPY --from=front-build /src/dist/microcrm/browser /app/front

# Le binaire caddy de l'image officielle a la capacité cap_net_bind_service :
# il peut écouter sur 80/443 sans être root
RUN addgroup -S microcrm \
    && adduser -S -G microcrm microcrm \
    && chown -R microcrm:microcrm /data /config

USER microcrm

EXPOSE 80
EXPOSE 443

FROM eclipse-temurin:17-jre-alpine AS back

RUN addgroup -S microcrm \
    && adduser -S -G microcrm microcrm

WORKDIR /app

COPY --from=back-build /src/build/libs/microcrm-0.0.1-SNAPSHOT.jar /app/back/microcrm-0.0.1-SNAPSHOT.jar

USER microcrm

EXPOSE 8080

CMD ["java", "-jar", "/app/back/microcrm-0.0.1-SNAPSHOT.jar"]

# Image tout-en-un (démonstration) : front + back pilotés par supervisord
FROM eclipse-temurin:17-jre-alpine AS standalone

RUN apk add --no-cache supervisor

COPY --from=caddy:2.8-alpine /usr/bin/caddy /usr/bin/caddy
COPY misc/docker/Caddyfile /etc/caddy/Caddyfile
COPY misc/docker/supervisor.ini /app/supervisor.ini
COPY --from=front-build /src/dist/microcrm/browser /app/front
COPY --from=back-build /src/build/libs/microcrm-0.0.1-SNAPSHOT.jar /app/back/microcrm-0.0.1-SNAPSHOT.jar

WORKDIR /app

EXPOSE 80
EXPOSE 443
EXPOSE 8080

CMD ["/usr/bin/supervisord", "-c", "/app/supervisor.ini"]
