# AMINE · أمين

Approvisionnement des restaurants de Tunis. Application web en un seul fichier (`index.html`),
reliée à la base Supabase du projet « Amine ».

Le fichier ne contient que la clé publique (publishable) de Supabase, prévue pour être publiée :
tous les contrôles d'accès sont faits dans la base. Aucune clé secrète ne doit être ajoutée ici.

Fichiers de l'application installable (écran d'accueil, ouverture hors connexion) :
`manifest.webmanifest`, `sw.js` (service worker : ne met en cache que cette page et ses icônes,
jamais les données Supabase) et les icônes `*.png`.

Version 8 (schéma 5, inchangé depuis) : la base Supabase doit avoir reçu le script SQL de cette version (`amine.sql`,
à coller dans Supabase › SQL Editor ; il peut être rejoué sans risque) **avant** de publier cette page,
sinon l'application affiche « mise à jour de la base nécessaire ».

Le service worker affiche aussi les notifications push (application fermée) quand l'envoi est
activé dans l'administration et la fonction Supabase « amine-push » déployée.

Dossier `photos/` : images des articles du catalogue (JPEG, 360 à 480 px de côté). Elles viennent de trois sources :
la plupart sont **générées par IA** et fournies par l'exploitant, d'autres sont **découpées dans les
catalogues et planches produits envoyés par le dépôt**, et les fichiers `planche-*.jpg` sont **découpés dans
les six planches sans marque fournies par l'exploitant le 10/11/2026** (fromages, volailles et œufs, pâtes,
boissons, emballages, entretien). Ces dernières sont des illustrations génériques : elles montrent le type de
produit, pas l'emballage exact. **Depuis le 11/11/2026, les produits en vente ne sont illustrés que par ces
planches** ; les autres fichiers ne servent plus qu'au catalogue de référence qu'un dépôt peut importer. Aucune
photo ne porte de licence ni de crédit, et les emballages de marque que montrent les plus anciennes peuvent ne
pas correspondre exactement aux produits vendus. Un dépôt
peut les remplacer article par article (fiche produit) ou en masse avec « Photos réelles » (Wikimedia Commons,
Open Food Facts, crédit enregistré). Les articles sans photo ne sont pas proposés aux restaurants.

Dossier `ocr/` : lecture des photos dans l'assistant de commande (bouton « + », appareil photo ou galerie).
La lecture se fait sur l'appareil, avec Tesseract.js 7.0.0 (Apache-2.0) et les données de langue français et arabe
(tessdata, Apache-2.0). Ces fichiers ne sont chargés qu'à la première photo, soit environ 8 Mo. Le worker
et le moteur WebAssembly de ce dossier sont autorisés par la politique de sécurité de cette page
(`script-src 'self' 'wasm-unsafe-eval'`) ; c'est ce qui distingue cette version de la version sans lecture.
La lecture par l'IA distante (fonction `amine-read-photo`) n'est pas déployée : aucune photo ne quitte
l'appareil tant qu'elle ne l'est pas.
