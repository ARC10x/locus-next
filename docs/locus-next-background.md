# Locus Next 1.5.1 — arrière-plan

La session de vérification détient une CLBackgroundActivitySession pendant la simulation et l’invalide à l’arrêt. L’expiration du délai UIKit ne bloque plus les commandes lorsque le suivi de localisation reste autorisé et actif. Les contrôles de confirmation restent inchangés.

Le scénario lancé au premier plan peut continuer en arrière-plan tant qu’iOS lui accorde du temps. Il n’y a aucune garantie après fermeture forcée, arrêt système ou perte du tunnel. La session de localisation n’est pas un ordonnanceur garantissant le réveil à une heure précise.

Les nouveaux voyages enregistrent la date de départ du domicile. Une suspension consomme seulement l’attente initiale : aucune portion de route ou de vol n’est sautée. Une reprise tardive décale donc l’arrivée. Les anciennes sauvegardes sans date conservent leur comportement. Un scénario interrompu après passage en arrière-plan est repris au retour dans l’app, sauf pause ou arrêt explicite.

## Validation sur iPhone requise

Créer un nouveau parcours dont le départ domicile est dans 2 minutes, démarrer puis verrouiller 3 minutes. Observer la position dans Plans avant de revenir dans Locus, puis exporter le journal. Refaire avec 10 minutes de trajet et contrôler la continuité. Tester Pause, Arrêter et Rester ici pour vérifier l’absence de reprise involontaire. Une confirmation verte seule ne prouve pas que le trajet a avancé pendant le verrouillage.

Référence Apple : https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
