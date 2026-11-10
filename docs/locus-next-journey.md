# Locus Next Test 1.5.0 — scénarios simulés

## Parcours équipage Orly → Dublin

Accessible dans Vol → Domicile → Orly → Dublin. Le domicile est saisi une seule fois et conservé dans UserDefaults sur l’iPhone. Aucune adresse privée n’est incluse dans le dépôt. Apple reçoit l’adresse pour le géocodage et les points pour les itinéraires.

Le scénario utilise le prochain horaire quotidien configurable en Europe/Paris (08:00 par défaut, **fictif**, aucun numéro de vol réel recherché). Si le temps nécessaire au trajet, à la préparation, à l’accès, à la préparation à bord et à la marge dépasse le temps disponible, il sélectionne le jour suivant. Le planning et la carte sont présentés avant lancement.

Le trajet routier utilise MKDirections puis le moteur DriveWalker existant (virages, accélération et freinage). Préparation équipage au siège, accès à l’avion estimé et préparation à bord précèdent le vol. Le bouton de lancement place la simulation au domicile, attend l’heure prévue, puis enchaîne les étapes. La progression est sauvegardée ; pause/suspension ne provoque aucun rattrapage instantané. L’exécution continue écran verrouillé reste soumise aux limites iOS et à la vérification de position.

## Réalisme et limites

- Durée automatique : suppression de l’étirement global qui ralentissait décollage et montée. Les anciennes durées imposées incompatibles sont refusées.
- L’altitude reste nulle pendant l’accélération initiale ; rotation à la fin du segment de décollage.
- Trajectoire aérienne avec points de passage et raccordements arrondis, vitesse calculée suivant la longueur parcourue.
- Pistes Orly 25 et Dublin 28L : extrémités géographiques OurAirports. Pistes fixes, pas de choix selon météo ou NOTAM.
- Roulages calculés sur le graphe des taxiways/taxilanes OpenStreetMap : environ 2,7 km à Orly et 2,8 km à Dublin. Connexion de 33 m à l’extrémité de piste à Orly. Stationnements fictifs sur le réseau, pas de porte affectée par la compagnie. Les sens de circulation et autorisations ATC ne sont pas reproduits. **Accès équipage entre le siège et l’avion estimé** ; aucun trajet interne validé.
- Ni procédures SID/STAR, ni autorisation ATC, ni simulation certifiée des performances. Altitude affichée au-dessus du sol de référence du scénario, non injectée dans le moteur Developer.
- Les sauvegardes de l’ancien modèle ne sont pas reprises sur une géométrie différente pour éviter un saut de position. Démarrer un nouveau scénario après mise à jour.
- Le problème 5G n’est pas déclaré corrigé.

## Promenade

Vol → Promenade en ville : domicile ou repère de carte, durée souhaitée, rayon maximal et pauses. Trois étapes puis retour par les itinéraires piétons Apple Plans. Les routes sortant du rayon ou non raccordées sont rejetées. Le temps final est recalculé, pas forcé en changeant la vitesse. Courtes jonctions (20 m maximum) entre points accrochés au réseau piéton ; aucun POI café/parc confirmé automatiquement pour cette première version.

## Sources géographiques

- Siège Transavia, 7 avenue de l’Union, Immeuble Bélaïa : https://corporate.transavia.com/fr-FR/juridique/confidentialite/
- Coordonnées des pistes, téléchargées le 9 novembre 2026 : https://github.com/davidmegginson/ourairports-data/blob/main/runways.csv
- OurAirports (données publiques) : https://ourairports.com/data/

## Validation

Tests de rotation, continuité, vitesse réelle le long du tracé, refus des durées étirées, horaires Paris et changement d’heure, sérialisation des étapes et rejet des raccords invalides. Compiler l’app iPhone et exécuter les tests macOS en CI avant livraison. Tests réseau MapKit et test complet sur iPhone nécessaires après livraison ; non remplaçables par les tests purs.

- Taxiways : © OpenStreetMap contributors, ODbL, extraits API 0.6 du 9 novembre 2026. Coordonnées dérivées dans OrlyDublinScenario ; https://www.openstreetmap.org/copyright .
