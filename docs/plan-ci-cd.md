# MicroCRM – Plan d'intégration et de déploiement continus

Ce document fixe les règles et objectifs de l'automatisation **avant** toute mise en œuvre technique du pipeline.
Il couvre trois volets : le plan de testing périodique, le plan de sécurité, et les principes de conteneurisation et de déploiement.

## 0. Contexte du projet

| Élément | Situation actuelle |
|---|---|
| Dépôt | Monorepo GitHub (`main`), deux composantes : `back/` et `front/` |
| Back-end | Java 17, Spring Boot 3.2, Spring Data REST/JPA, base HSQLDB en mémoire, build Gradle |
| Front-end | Angular 17, tests Jasmine/Karma (Chrome Headless), couverture via `karma-coverage` |
| Tests existants (back) | `MicroCRMApplicationTests` (chargement du contexte Spring), `PersonRepositoryIntegrationTest` (`@DataJpaTest`, recherche par e-mail) |
| Tests existants (front) | 8 tests unitaires (`*.spec.ts`) : composants `App`, `MainDashboard`, `OrganizationDetails`, `PersonDetails`, services `Person` et `Organization` |
| Conteneurisation | Un `Dockerfile` multi-stage (cibles `front`, `back`, `standalone`) et un `docker-compose.yml` (services `front` + `back`) |
| Outils retenus | GitHub Actions (CI/CD), SonarQube Cloud (qualité/sécurité), GitHub Container Registry – GHCR (images) |

Le projet est petit, sans base de données externe ni environnement de production existant : les plans ci-dessous restent volontairement simples et réalistes.

---

## 1. Plan de testing périodique

### 1.1 Types de tests exécutés

| Partie | Type de test | Outil / commande | Ce qui est vérifié |
|---|---|---|---|
| Back | Tests unitaires et d'intégration | `./gradlew test` (JUnit 5, Spring Boot Test) | Démarrage du contexte Spring, accès aux données JPA (repositories) |
| Back | Build | `./gradlew build` | Compilation et production du JAR exécutable |
| Back | Couverture de code | JaCoCo (plugin Gradle) | Rapport XML transmis à SonarQube Cloud |
| Front | Tests unitaires | `npm run test:ci` (Chrome Headless, sans mode watch, avec couverture) | Création des composants, appels HTTP des services |
| Front | Build de production | `npx ng build --configuration production` | Compilation TypeScript et bundle de production valides |
| Front | Couverture de code | `karma-coverage` (reporter `lcov`) | Rapport `lcov.info` transmis à SonarQube Cloud |
| Global | Build des images Docker | `docker build --target front` / `--target back` | Les images se construisent à partir des sources |

Les tests de bout en bout (E2E) ne sont pas retenus pour l'instant : le projet n'en contient pas et leur mise en place dépasse le périmètre. Ils pourront être ajoutés plus tard (par ex. Cypress ou Playwright contre l'environnement `docker compose`).

### 1.2 Moments d'exécution

| Déclencheur | Tests back | Tests front | Analyse Sonar | Build images | Publication images |
|---|:-:|:-:|:-:|:-:|:-:|
| `push` sur une branche de travail | ✅ | ✅ | ✅ | – | – |
| `pull_request` vers `main` | ✅ | ✅ | ✅ (+ Quality Gate bloquante) | ✅ (sans publication) | – |
| `push` / merge sur `main` | ✅ | ✅ | ✅ | ✅ | ✅ (tag `latest` + SHA) |
| Tag de version `vX.Y.Z` | ✅ | ✅ | ✅ | ✅ | ✅ (tag `X.Y.Z`) |
| Planifié (`schedule`, chaque lundi 6 h) | ✅ | ✅ | ✅ | – | – |
| Manuel (`workflow_dispatch`) | ✅ | ✅ | ✅ | optionnel | optionnel |

- Les jobs back et front s'exécutent **en parallèle** pour réduire la durée du pipeline.
- Le run **planifié hebdomadaire** détecte les régressions qui n'arrivent pas par le code : nouvelle version d'une dépendance, nouvelle règle Sonar, nouvelle vulnérabilité publiée (CVE).
- Une **protection de branche** sur `main` impose que la PR passe tous les contrôles avant fusion. Aucun push direct sur `main`.

### 1.3 Objectifs associés

| Objectif | Moyen | Critère de réussite |
|---|---|---|
| **Validation fonctionnelle** | Tests unitaires/intégration back et front à chaque push et PR | 100 % des tests passent, sinon le pipeline échoue |
| **Non-régression** | Exécution systématique de toute la suite avant fusion sur `main` + run hebdomadaire | Aucune PR fusionnée avec un test en échec |
| **Qualité** | Couverture mesurée et envoyée à SonarQube Cloud, Quality Gate | Couverture du nouveau code ≥ 80 % (objectif progressif pour le code existant) |
| **Livrable valide** | Build du JAR, du bundle Angular et des images Docker | Les artefacts se construisent sans erreur |
| **Retour rapide** | Jobs parallèles, cache Gradle et npm | Pipeline de PR en moins de 10 minutes |

Les rapports de tests et de couverture sont conservés comme **artefacts** du pipeline (rétention 14 jours) pour pouvoir analyser un échec.

---

## 2. Plan de sécurité

### 2.1 Rôle de l'analyse SonarQube Cloud

SonarQube Cloud réalise une **analyse statique** du code back (Java) et front (TypeScript) à chaque push et PR. Son rôle :

- détecter au plus tôt les failles et défauts, avant qu'ils n'atteignent `main` ;
- centraliser les indicateurs de qualité (bugs, sécurité, maintenabilité, couverture, duplication) ;
- **bloquer** une PR via la **Quality Gate** si le nouveau code ne respecte pas les seuils ;
- afficher le résultat directement dans la PR GitHub (décoration de PR).

Le projet est configuré en *monorepo* : un projet Sonar unique avec `sonar.sources=back/src/main,front/src` et l'import des rapports de couverture JaCoCo (back) et LCOV (front).

### 2.2 Types de problèmes surveillés

| Catégorie | Exemples | Traitement attendu |
|---|---|---|
| **Vulnérabilités** | Injection, désérialisation risquée, secrets en dur, CORS trop permissif | Bloquant : correction obligatoire avant fusion |
| **Security Hotspots** | Code sensible à relire (config CORS, regex, appels HTTP) | Revue manuelle obligatoire (100 % des hotspots revus) |
| **Bugs** | `NullPointerException` possible, `Optional.get()` sans vérification, erreurs de logique | Bloquant si sévérité élevée |
| **Code smells** | Duplication (ex. dépendance JPA déclarée deux fois dans `build.gradle`), code mort, complexité | Corrigés progressivement, non bloquants sauf seuil de maintenabilité |
| **Couverture et duplication** | Nouveau code non testé, blocs dupliqués | Seuils de la Quality Gate |

**Quality Gate retenue** (« Sonar way » adaptée, appliquée au *nouveau code*) :
- 0 nouvelle vulnérabilité, 0 nouveau bug ;
- note de sécurité, fiabilité et maintenabilité = A ;
- 100 % des Security Hotspots revus ;
- couverture ≥ 80 % ;
- duplication ≤ 3 %.

### 2.3 Bonnes pratiques attendues dans la CI

**Gestion des secrets**
- Aucun secret dans le code ni dans les fichiers de workflow : utilisation exclusive des **GitHub Secrets** (`SONAR_TOKEN`, identifiants de registre si besoin).
- Publication sur GHCR avec le `GITHUB_TOKEN` éphémère fourni par GitHub, pas de jeton personnel.
- **Permissions minimales** déclarées dans chaque workflow (`contents: read` par défaut, `packages: write` uniquement pour le job de publication).
- Les secrets ne sont pas exposés aux PR provenant de forks.
- Activation du **secret scanning** et de la *push protection* GitHub.

**Dépendances**
- Installations reproductibles : `npm ci` (respect du `package-lock.json`) et Gradle Wrapper versionné.
- **Dependabot** activé pour npm, Gradle, GitHub Actions et Docker (PR de mise à jour hebdomadaires, elles-mêmes testées par le pipeline).
- Audit des dépendances : `npm audit --audit-level=high` côté front, analyse des dépendances Gradle (Dependabot alerts / OWASP Dependency-Check) côté back.
- Actions GitHub tierces épinglées sur une version précise (idéalement un SHA de commit).

**Images Docker**
- Images de base à **version fixée** (aujourd'hui `FROM node` est sans version : à remplacer par `node:20-alpine`, par exemple).
- Scan des images construites avec **Trivy** : échec du pipeline en cas de vulnérabilité `CRITICAL`.
- Exécution des conteneurs avec un utilisateur non-root (point d'amélioration du `Dockerfile` actuel).

---

## 3. Principes de conteneurisation et de déploiement

### 3.1 Rôle du Dockerfile existant

Le `Dockerfile` à la racine est **multi-stage**. Il compile les sources dans des images de build complètes, puis copie seulement le résultat dans des images d'exécution minimales :

| Stage | Image de base | Rôle |
|---|---|---|
| `front-build` | `node:20-alpine` | `npm ci` puis build Angular de production |
| `back-build` | `gradle:8.7-jdk17-alpine` | `gradle bootJar` produit le JAR exécutable |
| `front` | `caddy:2.8-alpine` | Sert les fichiers statiques Angular (ports 80/443, HTTPS local, repli sur `index.html` pour le routage) |
| `back` | `eclipse-temurin:17-jre-alpine` | Lance le JAR Spring Boot (API sur le port 8080) |
| `standalone` | `eclipse-temurin:17-jre-alpine` | Front + back dans un seul conteneur piloté par **supervisord** (démonstration) |

Intérêt : une même recette produit un environnement identique en local, en CI et en déploiement, sans installer Java ni Node sur la machine cible.

#### Vérification du Dockerfile d'origine

| Constat | Risque | Correction |
|---|---|---|
| Images d'exécution `alpine:3.19` + `apk add caddy` / `apk add openjdk21-jre-headless` | Paquets installés à la main, non maintenus comme une image officielle ; Alpine 3.19 n'est plus supportée | Images officielles `caddy` et `eclipse-temurin`, déjà prêtes et mises à jour par leurs mainteneurs |
| Exécution avec un **JRE 21** d'un code compilé pour **Java 17** | Écart entre l'environnement testé (CI, JDK 17) et la production | `eclipse-temurin:17-jre-alpine` : même version que la CI |
| `FROM node` sans version | Build non reproductible, version de Node changeante | `node:20-alpine` |
| `EXPOSE 4200` sur l'API | Documentation de port fausse (l'API écoute sur 8080) | `EXPOSE 8080` |
| Conteneurs exécutés en `root` | Une faille applicative donne les droits root dans le conteneur | Utilisateur dédié `microcrm` pour `front` et `back` |
| `./gradlew build` dans l'image | Re-téléchargement de Gradle, tests exécutés une seconde fois | `gradle bootJar` (Gradle 8.7 inclus dans l'image) ; les tests sont faits par la CI |
| Copie de tout le dossier `front` avant `npm ci` | Toute modification de code invalide le cache des dépendances | `package*.json` copiés d'abord, `npm ci` mis en cache |
| Image `standalone` construite par copie de systèmes de fichiers entiers (`COPY --from=front / /`) | Image lourde et fragile (fichiers système écrasés) | Ne copie que le binaire `caddy`, le build Angular et le JAR |

#### Choix des images de base

| Image | Pourquoi |
|---|---|
| `eclipse-temurin:17-jre-alpine` | Distribution **officielle** d'OpenJDK par la fondation Eclipse (Adoptium), « Docker Official Image ». Remplace `openjdk`, dépréciée et plus mise à jour. **JRE** seulement (pas de compilateur), base Alpine : ~190 Mo contre ~400 Mo pour un JDK. |
| `caddy:2.8-alpine` | Image **officielle** Caddy, ~50 Mo. Le binaire a la capacité `cap_net_bind_service`, ce qui permet d'écouter sur 80/443 **sans être root**. HTTPS automatique. |
| `node:20-alpine` | Image **officielle** Node.js. Node 20 est la dernière LTS supportée par Angular 17. Elle ne sert qu'à la compilation : elle n'est **pas présente dans l'image livrée**. |
| `gradle:8.7-jdk17-alpine` | Image **officielle** Gradle, même version que le Gradle Wrapper du projet. Utilisée uniquement pour la compilation. |

Variantes *alpine* plutôt que *slim* (Debian) : elles sont encore plus petites, donc moins de paquets et moins de vulnérabilités potentielles. Les images de build lourdes (Node, Gradle, JDK) ne se retrouvent jamais dans les images finales grâce au multi-stage.

#### Bonnes pratiques de sécurité appliquées

- Images officielles à version fixée, aucune image `latest` dans le `Dockerfile`.
- Utilisateur non-root (`microcrm`) dans les images `front` et `back`.
- Image d'exécution sans outils de build ni code source (seulement le JAR ou les fichiers statiques).
- `.dockerignore` : exclut `node_modules`, `build`, `.git`, rapports de tests… du contexte de build.
- Dans `docker-compose.yml` : `cap_drop: ALL` sur les deux services (seule `NET_BIND_SERVICE` est rendue à `front`) et `no-new-privileges` sur `back`.
- Scan des images : **Trivy** (open source, Aqua Security), équivalent gratuit de Twistlock / Prisma Cloud, exécuté dans le job `docker` de la CI. Les vulnérabilités HIGH et CRITICAL sont affichées ; le job échoue sur une vulnérabilité CRITICAL pour laquelle un correctif existe. Commande locale : `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.58.0 image orion-microcrm-back:latest`.

Limite connue : l'URL de l'API est codée en dur dans le front (`front/src/app/config.ts` : `http://localhost:8080`). Elle convient en local, mais devra être rendue configurable pour un déploiement réel. L'image `standalone` s'exécute en root, car supervisord pilote deux processus ; elle est réservée à la démonstration.

### 3.2 Rôle de docker-compose

Le fichier `docker-compose.yml` à la racine sert à :

- **orchestrer** les deux services `front` et `back` (images construites depuis les cibles du `Dockerfile`), avec leurs ports et un réseau commun ;
- lancer toute l'application avec **une seule commande** (`docker compose up --build`), en local comme sur un serveur ;
- servir d'environnement d'intégration en CI : démarrage de la stack puis test de santé (`curl` sur l'API et le front) ;
- en déploiement, référencer les **images publiées sur GHCR** au lieu de les reconstruire (`docker compose pull && docker compose up -d`).

Les cibles `front` + `back` sont privilégiées avec compose. L'image `standalone` reste disponible pour une démonstration en un seul conteneur.

### 3.3 Stratégie de déploiement envisagée

**Publication des images**
- Registre : **GitHub Container Registry** (`ghcr.io/<compte>/microcrm-front` et `ghcr.io/<compte>/microcrm-back`).
- Publication uniquement depuis `main` (et les tags de version), **après** succès des tests, de la Quality Gate Sonar et du scan Trivy.
- Étiquetage :
  - `sha-<commit>` : traçabilité exacte de chaque build ;
  - `latest` : dernière version validée de `main` ;
  - `X.Y.Z` : versions publiées via un tag Git `vX.Y.Z` (versionnage sémantique).

**Déploiement automatisé**

```
push/PR ──► Tests back + front ──► SonarQube Cloud (Quality Gate) ──► Build images ──► Scan Trivy
                                                                                          │
                                                       (main uniquement)                  ▼
                                                                         Publication GHCR (latest, sha, version)
                                                                                          │
                                                                                          ▼
                                                                  Déploiement : docker compose pull && up -d
```

- **Intégration continue** (toutes branches) : tests, analyse, build.
- **Livraison continue** (`main`) : images publiées automatiquement et prêtes à être déployées.
- **Déploiement** : sur un environnement cible (VM ou serveur de démonstration), un job déclenché après la publication récupère les nouvelles images et relance la stack avec `docker compose`. En l'absence d'infrastructure fournie dans le cadre du projet, ce déploiement est d'abord manuel (`workflow_dispatch`) et validé localement. Il sera automatisé quand une cible sera disponible.
- **Retour arrière** : redéployer le tag d'image précédent (`sha-…` ou `X.Y.Z`). Les images étant immuables, le retour arrière est rapide.
- **Vérification post-déploiement** : test de santé sur l'API (`/`) et sur le front. En cas d'échec, l'équipe est alertée et la version précédente est remise en place.

---

## 4. Synthèse des actions à mener (mise en œuvre)

1. ✅ Corriger le `Dockerfile` (`EXPOSE 8080`, versions d'images fixées, back non-root).
2. ✅ Ajouter `docker-compose.yml`.
3. ✅ Ajouter JaCoCo (back) et les reporters `lcov` + JUnit (front).
4. ✅ Écrire le workflow CI GitHub Actions (tests → Sonar → build des images).
5. Créer le projet SonarQube Cloud, le secret `SONAR_TOKEN` et la Quality Gate.
6. Ajouter le scan Trivy et la publication GHCR (pipeline CD).
7. Ajouter la configuration Dependabot.
8. Activer la protection de la branche `main`.

---

## 5. Mise en œuvre du pipeline CI

Le pipeline est décrit dans un seul fichier, `.github/workflows/ci.yml`, qui centralise toute la logique d'automatisation.

### 5.1 Déclencheurs

| Déclencheur | Raison |
|---|---|
| `push` (toutes branches, tags `v*`) | Retour rapide au développeur à chaque push |
| `pull_request` vers `main` | Contrôle obligatoire avant fusion (non-régression) |
| `schedule` (lundi 6 h UTC) | Détecter les régressions dues aux dépendances ou aux nouvelles règles Sonar |
| `workflow_dispatch` | Relancer le pipeline manuellement |

`concurrency` annule un run devenu obsolète quand un nouveau commit arrive sur la même branche, ce qui évite de consommer des minutes inutilement.

### 5.2 Jobs

```
back ──┐
       ├──► sonar   (analyse + Quality Gate)
front ─┤
       └──► docker  (build des images back et front, sans publication)
```

| Job | Étapes | Résultats visibles |
|---|---|---|
| `back` | JDK 17 Temurin, cache Gradle, `./gradlew build` (compilation, tests JUnit, rapport JaCoCo) | Check « Tests back-end » sur le commit/PR, artefact `back-reports` (rapports HTML de tests et de couverture) |
| `front` | Node 20, cache npm, `npm ci`, `npm audit`, `npm run test:ci` (Karma en Chrome Headless + couverture), build de production | Check « Tests front-end », artefact `front-coverage` |
| `sonar` | Récupère les classes compilées et les rapports de couverture, lance l'analyse et attend la Quality Gate | Tableau de bord SonarQube Cloud, commentaire et statut sur la PR, échec du job si la Quality Gate n'est pas respectée |
| `docker` | Build des cibles `back` et `front` du `Dockerfile` (matrice), cache GitHub Actions | Vérifie que les images se construisent ; la publication relève du pipeline CD |

Les jobs `back` et `front` tournent **en parallèle**. `sonar` et `docker` ne s'exécutent que si les deux premiers réussissent : on n'analyse pas et on ne construit pas d'image à partir d'un code dont les tests échouent.

### 5.3 Justification des choix

- **Actions officielles et maintenues** : `actions/checkout`, `actions/setup-java`, `actions/setup-node`, `actions/upload-artifact` / `download-artifact` (GitHub), `gradle/actions/setup-gradle` (Gradle), `SonarSource/sonarqube-scan-action` (SonarSource), `docker/setup-buildx-action` / `docker/build-push-action` (Docker). Elles sont documentées et épinglées sur une version majeure.
- **`mikepenz/action-junit-report`** : action largement utilisée qui transforme les rapports JUnit XML en *check* GitHub lisible (tests réussis/échoués, message d'erreur), sans avoir à ouvrir les logs. Côté front, `karma-junit-reporter` produit ce format.
- **Script `npm run test:ci`** : exécution unique (`--watch=false`) en Chrome Headless sans sandbox, nécessaire sur les runners Linux, avec couverture. La même commande sert en local et en CI.
- **Couverture** : JaCoCo (XML) côté back et `lcov` côté front sont les formats importés nativement par SonarQube Cloud.
- **Une seule analyse Sonar pour le monorepo** (`sonar-project.properties` à la racine) : un seul tableau de bord et une seule Quality Gate pour l'application. `fetch-depth: 0` donne à Sonar l'historique git nécessaire pour identifier le nouveau code.
- **`-Dsonar.qualitygate.wait=true`** : le pipeline échoue si la Quality Gate échoue, ce qui applique le plan de sécurité (section 2.2).
- **Secrets** : le jeton Sonar est lu dans `secrets.SONAR_TOKEN`. S'il est absent (PR depuis un fork), l'analyse est ignorée avec un avertissement au lieu d'échouer.
- **Permissions minimales** : `contents: read` par défaut ; `checks: write` seulement pour les jobs qui publient un rapport de tests.
- **Audit npm non bloquant** : Angular 17 comporte des vulnérabilités connues (sévérité haute) qui ne se corrigent qu'en migrant vers une version majeure plus récente (Angular 19 ou au-delà). Le résultat reste visible dans les logs du job ; la migration est une action de suivi.
- **Caches** (Gradle, npm, couches Docker) : réduisent la durée du pipeline, conformément à l'objectif « retour rapide » (section 1.3).

### 5.4 Configuration SonarQube Cloud (une seule fois)

1. Se connecter à [sonarcloud.io](https://sonarcloud.io) avec GitHub et importer le dépôt.
2. Vérifier que l'organisation et la clé du projet correspondent à `sonar.organization` et `sonar.projectKey` dans `sonar-project.properties`.
3. **Désactiver l'analyse automatique** (*Administration → Analysis Method*) : elle entre en conflit avec l'analyse lancée par la CI.
4. Générer un jeton (*My Account → Security*) et l'enregistrer dans GitHub : *Settings → Secrets and variables → Actions → New repository secret*, nom `SONAR_TOKEN`.
