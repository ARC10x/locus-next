# Locus Next — première version de test

Cette branche prépare la V1 de stabilité à partir du fork 1.3.0, commit
`e0bee53a83adad848a7b178793c0fbe199ae37fb`. Ce document décrit le code et le
protocole de validation ; il ne vaut pas validation sur iPhone.

## Installation séparée

Le workflow **Locus Next Test IPA** produit `Locus-Next-Test.ipa`, non signée,
dans l'artefact de son exécution. Extraire le ZIP GitHub avant Sideloadly.
Nom : **Locus Next Test**. Identifiant : `com.chrismack.locusnext.dev`.
Conserver cet identifiant distinct lors de la signature pour garder Locus 1.3.0.
La copie de test a son propre stockage : réimporter le fichier RPPairing localement.
Ne pas mettre ce fichier dans GitHub ni dans les diagnostics.

Configuration ciblée : iPhone 15, iOS 18.7.8, Sideloadly, compte Apple gratuit,
mode Developer et LocalDevVPN externe. Conserver dans LocalDevVPN :
Tunnel IP `10.7.0.2/30`, Device IP `10.7.0.1/32`. La cible du moteur est
`10.7.0.1` sans suffixe CIDR. L'app de test n'embarque ni VPN ni widget et
ne modifie pas la configuration LocalDevVPN.

## Comportements introduits

- Correction de la convergence à vitesse nulle avant un arrêt à pied ; les
  pauses routières aléatoires ne sont plus imposées à la marche.
- L'accusé de réception du moteur reste « vérification en cours ». Le statut
  confirmé nécessite une lecture Core Location récente, précise, marquée
  simulée, cohérente avec une commande de la session courante.
- Position fixe : surveillance et renvoi périodique, sans garantie de maintien.
- Carte : choisir un repère puis **Aller au repère** recalcule depuis la
  dernière position acceptée, sans appeler l'effacement de simulation.
  Un calcul échoué conserve le parcours précédent. **Position fixe** arrête
  le mouvement ; **Arrêter** demande l'effacement de la simulation.
- Récupération : trois tentatives non concurrentes, ciblées à 0, 5 et 15 secondes
  depuis la détection. Une tentative lente décale les suivantes. La progression
  attend une confirmation avant de reprendre.
- Point de reprise : géométrie et arrêts choisis, profil, mode, tour, distance,
  vitesse, temps simulé et temps de pause restant. Écriture périodique et lors
  des pauses/transitions. Les anciens fichiers restent lisibles.
- Réglages → Locus Next → Simulation et diagnostics : état, dernière
  confirmation, reconnexion manuelle, export JSON des événements techniques.
  Aucun fichier d'appairage, coordonnée ou nom de réseau n'entre dans ce journal.
- Un import RPPairing est analysé avant remplacement atomique du précédent.

## Limites à vérifier sur l'appareil

iOS peut suspendre ou terminer l'app ; aucun minuteur ne s'exécute alors.
L'expiration du temps supplémentaire diffère les nouvelles commandes. Les
callbacks de localisation et le retour au premier plan permettent une nouvelle
vérification. La reprise après fermeture est explicite, depuis le point sauvegardé,
et peut perdre les dernières secondes avant la dernière écriture achevée.

Les droits de localisation, les notifications et les données Core Location sont
indispensables à la confirmation. Un manque de preuve reste non confirmé.
Les journaux de changement réseau/audio permettent de corréler une interruption
avec CarPlay ou Bluetooth ; ils ne prouvent pas sa cause. L'app ne coupe ni le
Bluetooth système ni le VPN externe. L'initialisation en cellulaire reste à
évaluer ; une reconnexion Wi-Fi peut encore être nécessaire.

Le moteur Developer transmet latitude/longitude seulement. L'altitude, la
vitesse aérienne, Live Flight Sync et le planificateur aérien ne font pas partie
de ce lot. La bibliothèque native fournie par le fork est conservée ; les tests
de logique n'en valident pas le transport ni la gestion mémoire.

## Validation automatique et manuelle

Le workflow exécute les XCTest de logique sur macOS, compile pour iPhone,
vérifie l'identifiant séparé, le schéma d'URL et l'absence d'extensions, puis
archive l'IPA. Il ne publie aucune release et ne modifie pas `main`.

Tests sur iPhone à effectuer avant de qualifier cette version de stable :

1. Importer un RPPairing valide, puis essayer un fichier invalide : le valide
   doit rester utilisable. Ne pas exporter son contenu.
2. Activer LocalDevVPN, choisir une position, attendre la confirmation puis
   comparer avec Plans. Vérifier l'affichage avec une permission refusée aussi.
3. Parcours à pied court, virage serré, pause explicite, arrivée exacte : pas de
   blocage, pas de nouvelle pause routière. Refaire à 0,5 / 1 / 2 / 4 Hz.
4. Choisir une nouvelle destination pendant un trajet et après l'arrivée.
   Plans ne doit pas repasser par la position réelle lors du changement.
5. Couper LocalDevVPN pendant une marche : progression suspendue, trois
   tentatives au maximum, statut non confirmé si échec. Rétablir puis relancer
   la vérification. Appuyer sur Arrêter pendant une reconnexion : aucune
   ancienne commande ne doit réactiver la simulation après l'effacement.
6. Fermer et rouvrir pendant une pause ou un retour : reprendre au bon endroit,
   dans le bon sens, avec le temps de pause restant et le même profil.
7. Verrouiller 10 min, 1 h puis une nuit sur secteur ; consigner l'heure de
   dernière confirmation et l'état constaté dans Plans après réouverture.
8. Tester Wi-Fi → cellulaire → Wi-Fi, Bluetooth, CarPlay filaire et sans fil.
   Exporter le journal et noter séparément les heures des actions.

Build local sur Mac :

```sh
python3 .github/scripts/logic-package.py
swift test
python3 .github/scripts/configure-next-build.py
xcodegen generate --spec project.next.yml
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/LocusNext.xcarchive CODE_SIGNING_ALLOWED=NO archive
python3 .github/scripts/package-next.py
```
