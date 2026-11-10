# Locus Next Test 1.4.0 — aviation simulée et surveillance

## Correctif 1.4.1 : démarrage en attente

Le journal iPhone du 9 novembre montre un accès TCP Developer réussi à 21:56:47
(Paris), mais aucune confirmation après 21:54:57. Les trois tentatives manuelles
de 22:02 ont de nouveau accédé au service sans produire de confirmation. Cela
localise le blocage côté vérification ; le journal ne permet pas de déterminer
si les lectures manquent, sont anciennes ou sont refusées pour un autre motif.

Le correctif relance le lecteur Core Location sans fermer la connexion Developer.
Il conserve les exigences de fraîcheur, précision, source simulée et concordance.
Les refus et l'état du lecteur rejoignent le journal sans coordonnées.
La relance est espacée d'au moins 15 secondes. Un simple requestLocation pendant
des mises à jour continues serait sans effet d'après la documentation Apple :
https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation()

Au démarrage du vol, si la lecture initiale n'est pas confirmée après trois
secondes, une seule avance sur le parcours est autorisée, limitée à cinq mètres
et quinze secondes de scénario. Le temps correspondant est attendu ; aucun
mouvement supplémentaire ni avancement sauvegardé n'est accepté sans confirmation.
Ce test vise le cas où le renvoi d'une position immobile ne produit pas de nouveau
fix. Il ne garantit pas qu'iOS en fournisse un.

Après trente secondes sans preuve et hors récupération moteur déjà engagée,
le scénario sauvegardé s'arrête avec une explication et un bouton de reprise.
Le transport ne boucle plus indéfiniment sur le même point en gardant le vol actif.
Un essai sur iPhone est indispensable ; la panne 5G reste indépendante et ouverte.

Cette version ajoute un moteur aérien indépendant du moteur routier. Les profils
Boeing 737-800, Airbus A320, Airbus A350, Boeing 777 et personnalisé sont des
préréglages illustratifs modifiables, pas des performances certifiées.

## Utilisation

Dans l'interface Pro, le bouton **Vol** apparaît à côté des modes terrestres.
Pour un premier essai : fixer une position de départ, choisir un repère d'arrivée
à au moins 30 km, ouvrir Vol et utiliser **Proposer un vol depuis ma position
simulée vers le repère**. Cette proposition construit des pistes fictives.

Pour définir des pistes manuellement, placer successivement un repère sur la
carte puis l'affecter au terminal de départ, début et fin de piste de départ,
seuil et fin de piste d'arrivée, terminal d'arrivée. Les pistes doivent mesurer
500 m à 6 km ; les terminaux doivent être à moins de 15 km de leur piste.
La sélection n'est pas reliée à une base officielle d'aéroports.

Choisir le profil et la vitesse sol de croisière (300 à 1 000 km/h). La durée 0
utilise la durée calculée ; une durée plus longue réduit les vitesses, une durée
trop courte est refusée. Le HUD propose km/h, mph et KTS, altitude du scénario,
vitesse verticale et cap. Les phases sont roulage, alignement, décollage, montée,
croisière, descente, approche, atterrissage et roulage d'arrivée.

La trajectoire comprend un départ et une approche alignés sur les pistes choisies
et des arcs entre les étapes. L'altitude demandée est réduite sur les vols courts.
Seules latitude et longitude sont transmises au moteur Developer ; altitude et
vitesse verticale ne sont pas des mesures ni des valeurs injectées dans iOS.

La progression attend une confirmation récente. Pause conserve le dernier point ;
Rester ici interrompt le scénario sans effacer la position. La sauvegarde de vol
est actualisée toutes les cinq secondes et lors des transitions. La reprise après
interruption se fait explicitement dans Vol. Pas de rattrapage brutal du temps
pendant lequel iOS a suspendu l'app.

## Retours iPhone et corrections

Les essais de la V1 ont été rapportés globalement positifs par l'utilisateur,
avec deux exceptions : notifications de reconnexion après verrouillage malgré
une position simulée encore affichée dans Plans ; fonctionnement 5G impossible.

La surveillance n'assimile plus 12 secondes sans nouvelles lectures à une panne.
Elle affiche Vérification en attente ; au retour au premier plan, elle rafraîchit
la session existante sans la déconnecter. Une lecture réelle récente et précise
après confirmation, une erreur de commande ou une action manuelle peuvent lancer
la récupération bornée. Une lecture réelle ancienne est ignorée.

La 5G reste non résolue tant qu'aucun diagnostic appareil ne permet d'identifier
la cause. Le journal distingue maintenant l'échec de connexion TCP à
10.7.0.1:49152, avant même l'appairage, des erreurs du moteur Developer. Le test
TCP manuel des réglages et les erreurs Core Location rejoignent le journal.
Aucun paramètre LocalDevVPN, protection Apple ou réglage cellulaire n'est modifié.

## Validation sur appareil à refaire

1. Position fixe puis verrouillage 1 minute et 10 minutes : pas de reconnexion
   provoquée uniquement par l'absence de lectures ; relever Plans et le journal.
2. Tester le TCP Developer en Wi-Fi puis en 5G, noter les heures et exporter le
   journal. Distinguer un démarrage directement en 5G d'une transition depuis Wi-Fi.
3. Essayer un vol fictif court, puis une piste définie manuellement. Vérifier les
   phases, la vitesse maximale et les unités, la pause, la reprise et Rester ici.
4. Couper le tunnel pendant le vol : le temps du scénario ne doit plus avancer.
   Rétablir la connexion et vérifier la reprise depuis le dernier point.
5. Fermer et rouvrir l'app : reprendre le vol sauvegardé et vérifier le profil,
   les pistes et la progression. Tester Arrêter pendant une reconnexion.

Cette livraison vise iOS 18, conformément au minimum de la bibliothèque native.
Live Flight Sync, recherche par numéro, données réelles, Replay historique,
planificateur de voyage et balade libre restent des étapes ultérieures.
