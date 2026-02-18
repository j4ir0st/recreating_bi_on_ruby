import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Configurar Stimulus
application.debug = false
window.Stimulus = application

export { application }
