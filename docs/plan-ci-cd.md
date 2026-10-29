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
| Back | Couverture de code | JaCoCo (plugin Gradle à ajouter) | Rapport XML transmis à SonarQube Cloud |
| Front | Tests unitaires | `npm test -- --watch=false --browsers=ChromeHeadlessNoSandbox --code-coverage` | Création des composants, appels HTTP des services |
| Front | Build de production | `npx ng build --configuration production` | Compilation TypeScript et bundle de production valides |
| Front | Couverture de code | `karma-coverage` (reporter `lcov` à ajouter) | Rapport `lcov.info` transmis à SonarQube Cloud |
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

Le `Dockerfile` à la racine est **multi-stage**. Il compile les sources dans des images de build lourdes, puis copie seulement le résultat dans des images d'exécution légères (Alpine) :

| Stage | Rôle |
|---|---|
| `front-build` | Image Node : `npm ci` puis build Angular optimisé |
| `back-build` | Image Gradle JDK 17 : `./gradlew build` produit le JAR (et exécute les tests) |
| `front` | Alpine + **Caddy** : sert les fichiers statiques Angular (ports 80/443, HTTPS local, repli sur `index.html` pour le routage) |
| `back` | Alpine + JRE 21 : lance le JAR Spring Boot (API sur le port 8080) |
| `standalone` | Regroupe front et back dans un seul conteneur piloté par **supervisord** (démo et tests rapides) |

Intérêt : une même recette produit un environnement identique en local, en CI et en déploiement, sans installer Java ni Node sur la machine cible.

Points à corriger avant l'automatisation :
- le stage `back` déclare `EXPOSE 4200` alors que l'API écoute sur **8080** ;
- l'image `node` n'est pas versionnée ;
- l'URL de l'API est codée en dur dans le front (`front/src/app/config.ts` : `http://localhost:8080`) : elle convient en local, mais devra être rendue configurable pour un déploiement réel.

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

1. Corriger le `Dockerfile` (`EXPOSE 8080`, version de l'image Node, utilisateur non-root).
2. Ajouter JaCoCo (back) et le reporter `lcov` (front) pour la couverture.
3. Créer le projet SonarQube Cloud, le secret `SONAR_TOKEN` et la Quality Gate.
4. Écrire le workflow GitHub Actions : tests → Sonar → build → scan → publication GHCR.
5. Ajouter la configuration Dependabot.
6. Activer la protection de la branche `main`.
