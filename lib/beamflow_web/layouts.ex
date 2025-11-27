defmodule BeamflowWeb.Layouts do
  @moduledoc """
  Módulo de layouts para las vistas de BeamflowWeb.

  Contiene los templates de layout (root y app) que definen
  la estructura HTML común para todas las páginas de la aplicación.

  Los templates embebidos se encuentran en `layouts/`:
  - `root.html.heex` - Layout base con DOCTYPE, head y body
  - `app.html.heex` - Layout de aplicación con navegación
  """

  use BeamflowWeb, :html

  embed_templates "layouts/*"
end
