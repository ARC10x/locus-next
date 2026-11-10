# Scénarios Locus Next 1.6.0

Vol → Bibliothèque → Importer un scénario JSON. L’import ne lance rien : une carte et une durée précèdent le bouton Démarrer. La bibliothèque conserve les fichiers localement et propose partage et suppression. Les vues voyage équipage, retour, promenade et vol manuel permettent aussi d’enregistrer le parcours calculé.

Les exports contiennent les coordonnées, éventuellement celles du domicile. Aucun fichier privé n’est publié automatiquement. Le fichier est un objet JSON avec formatVersion: 1, name et configuration (FlightConfiguration, modelVersion: 2). Taille maximale 8 Mo. Les points, vitesses, durées, raccords et versions sont contrôlés par le moteur avant enregistrement ou lancement. L’horaire de départ et l’attente initiale ne sont pas conservés : une route importée démarre immédiatement après confirmation.

Un nouveau parcours peut être fourni comme données sans recompilation ; une nouvelle fonctionnalité du moteur nécessite toujours une version. Les pistes, roulages et points de passage doivent être renseignés pour obtenir un parcours crédible. Importer un numéro de vol ne récupère pas des horaires réels.

Retour inclus : Dublin 10R → Orly 07, parcours réciproque simulé, taxiways inversés, sortie équipage de 15 minutes, liaison estimée vers le véhicule, route Apple Plans vers le domicile mémorisé. La carte et la durée sont vérifiées avant lancement. Pas de procédure ATC réelle.

Arrière-plan : le moteur ne termine plus une tâche au seul motif de 30 secondes sans lecture récente lorsque la session de localisation est autorisée en arrière-plan. Il conserve le scénario, relance son lecteur et attend la preuve sans avancer à l’aveugle. La reprise des routes voiture classiques au retour au premier plan est ajoutée, hors pause/arrêt explicites. Le cas utilisateur exact reste à confirmer par journal ; promenade signalée comme suspicion, non panne reproduite. iOS peut toujours suspendre le processus.

Validation appareil : tester voiture du scénario puis voiture de la carte, et promenade, en verrouillant 3 puis 10 minutes. Observer dans Plans avant de rouvrir Locus et exporter le journal. Tester Pause/Arrêter. Tester import/export après fermeture de l’app, retour complet et continuité taxi → sortie → voiture.
