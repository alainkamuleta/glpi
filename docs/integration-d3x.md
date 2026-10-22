# Intégration GLPI dans l'écosystème D3X — Command Center & n8n

> Document de conception. Statut : **à implémenter** (le déploiement GLPI est
> opérationnel ; l'intégration ci-dessous décrit la cible).

Ce document décrit comment GLPI s'insère dans la chaîne de gestion des
incidents D3X, depuis la **détection** (n8n / SOC) jusqu'à la **clôture**, en
passant par l'**indicateur d'incidents** affiché dans le Command Center.

---

## 1. Rôle de GLPI dans D3X

GLPI est le **référentiel de gestion des incidents** (helpdesk/ITSM) de la
plateforme. Il centralise :

- les **tickets d'incident** (type `Incident` = 1) créés automatiquement par
  n8n à partir des alertes SOC (Wazuh, CTV-SIC, SNM-DPI, CrowdSec) ;
- le **cycle de vie** de chaque incident (statut) ;
- l'**historique** (suivi, solutions, escalades) ;
- les **indicateurs** consommés par le Command Center.

## 2. Cycle de vie des incidents (GLPI ⇄ processus D3X)

Correspondance entre le processus D3X et les statuts natifs GLPI :

| Étape D3X | Statut GLPI | Constante | Description |
|---|---|---|---|
| **Détection** | Nouveau | `INCOMING` = 1 | n8n crée le ticket (type `Incident`) suite à une alerte SOC |
| **Qualification** | En cours (attribué) | `ASSIGNED` = 2 | Un analyste qualifie : catégorie, urgence, impact, priorité |
| **Escalade** | En cours (planifié) | `PLANNED` = 3 | Incident prioritaire : escalade vers un niveau supérieur |
| **Résolution** | Résolu | `SOLVED` = 5 | Correctif appliqué, solution documentée |
| **Clôture** | Clos | `CLOSED` = 6 | Vérification post-résolution, clôture définitive |

> `WAITING` = 4 (en attente) sert d'état intermédiaire (ex. en attente d'un
> tiers ou d'une fenêtre de maintenance).

Priorité = f(urgence × impact), calculée par GLPI à partir des champs natifs
`urgency` (1..5) et `impact` (1..5).

## 3. Mécanisme n8n de création et de traitement des incidents

### 3.1 Flux de création (détection → GLPI)

Un workflow n8n dédié (`glpi_incident_create`, à créer dans le repo
`convergence-n8n`) réagit aux alertes SOC :

```
[Wazuh / CTV-SIC / SNM-DPI / CrowdSec]
        │  webhook (POST JSON)
        ▼
[ n8n : workflow "glpi_incident_create" ]
        │
        ├─ 1. initSession        → GET  /apirest.php/initSession
        │                          (user-token ou user:password + App-Token)
        ├─ 2. POST /Ticket        → création ticket (type=1, status=1)
        │      name      = titre normalisé de l'alerte
        │      content   = corps de l'alerte (source, IP, règle, etc.)
        │      type      = 1 (Incident)
        │      status    = 1 (Nouveau)
        │      urgency   = déduite de la criticité de l'alerte
        │      impact    = déduit de l'actif touché
        ├─ 3. killSession        → GET /apirest.php/killSession
        └─ 4. Notification Matrix (salle SOC) avec l'ID du ticket créé
```

### 3.2 Authentification API GLPI (pour n8n)

GLPI expose son API REST via `apirest.php` :

- **Endpoint** : `http://<glpi-host>/apirest.php/...`
- **Session** : `initSession` renvoie un `session_token` à présenter dans
  chaque appel (`Session-Token` header).
- **App-Token** : jeton applicatif généré dans GLPI
  (`Configuration > Générale > API`) — à stocker côté n8n (credentials),
  **jamais en clair dans un fichier versionné** (règle #6).

### 3.3 Traitement (mise à jour de statut par n8n)

n8n peut aussi faire **progresser** un incident :

- qualification automatique : `PUT /Ticket/<id>` avec `status=2`, `urgency`,
  `impact`, `itilcategories_id` ;
- escalade : `status=3` + notification au niveau supérieur ;
- résolution : `status=5` + `solution` ;
- clôture : `status=6`.

## 4. Intégration Command Center (indicateur d'incidents)

Le Command Center (MUD, `d3x-command-center`, port 8082 sur `sonde-01`)
consomme l'API GLPI pour afficher un **indicateur d'incidents** :

| Indicateur | Requête GLPI |
|---|---|
| Incidents ouverts (nouveaux + en cours) | `GET /search/Ticket?criteria[0][field]=status&criteria[0][searchtype]=equals&criteria[0][value]=1` (etc.) |
| Incidents par statut | `GET /search/Ticket` + agrégation par `status` |
| Incidents par priorité | agrégation par `priority` |
| Temps moyen de résolution | dérivé de `solvedate` − `date` |

**Mode d'accès conseillé** : le Command Center interroge GLPI via un
**endpoint interne** (LAN `192.168.1.41:8080` ou WireGuard `10.0.88.41:8080`),
pas via Internet — GLPI n'est **pas** exposé publiquement (voir §5).

L'affichage peut être :
- un **module/iframe** dédié dans le Command Center (à l'image des modules
  `LisuModule.tsx` / `DshModule.tsx` existants), ou
- une **carte KPI** alimentée par un petit service de lecture GLPI.

## 5. Exposition réseau (état cible)

- **Accès test immédiat** : `http://192.168.1.41:8080` (LAN) et
  `http://10.0.88.41:8080` (WireGuard).
- **À terme** : un DNS OVH dédié (ex. `glpi.exactelis.net`) routé via
  `nginxrp-haproxy` (front HAProxy dédié) → `sonde-01` (`10.0.88.41:8080`).
  **Non prioritaire** pour le moment (consigne d'Alain).
- GLPI **reste interne** : seuls le Command Center et n8n y accèdent
  directement ; l'accès humain passe par le VPN (WireGuard/Nebula) ou le
  reverse-proxy authentifié.

## 6. Règle #6 — versionnement

- Tout le code de déploiement (Dockerfile, compose, deploy_glpi.sh, doc) est
  versionné dans le fork `starck/glpi` (Gitea) et `alainkamuleta/glpi`
  (GitHub).
- Les **secrets** (mots de passe DB, App-Token GLPI, user-token n8n) ne sont
  **jamais** versionnés : ils vivent dans le `.env` local de déploiement
  (généré par `deploy_glpi.sh`, permissions 600) et dans les credentials n8n.
- Le futur workflow `glpi_incident_create.json` est versionné dans
  `convergence-n8n/workflows/` ; ses credentials restent dans le coffre n8n.
