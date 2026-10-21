package com.itinerarios.e2e;

import com.itinerarios.e2e.support.SeleniumTestBase;
import org.junit.jupiter.api.Test;
import org.openqa.selenium.By;
import org.openqa.selenium.JavascriptExecutor;
import org.openqa.selenium.WebElement;
import org.openqa.selenium.support.ui.ExpectedConditions;
import org.openqa.selenium.support.ui.WebDriverWait;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * Flujo E2E principal (sección 38 de la especificación maestra):
 *
 *   Open Angular -> Load airports -> Open map -> Create itinerary
 *   -> Validate airport -> Save itinerary -> Verify itinerary -> Edit -> Delete
 *
 * Tramo Nivel 2 (seccion 38): Create itinerary -> RabbitMQ -> Notification
 * -> Verify notification history, consultado por HTTP a traves del Gateway
 * (propiedad "e2e.gatewayUrl", por defecto http://localhost:8080).
 *
 * Requiere el stack completo levantado (docker compose up en
 * itinerarios-infrastructure) y accesible en la URL de la propiedad
 * de sistema "e2e.baseUrl" (por defecto http://localhost:4200).
 */
class ItineraryFullFlowE2ETest extends SeleniumTestBase {

    private static final String TEST_USER = "Selenium E2E";
    private static final String DEPARTURE_IATA = "BOG";
    private static final String ARRIVAL_IATA = "MDE";
    private static final String GATEWAY_URL = System.getProperty("e2e.gatewayUrl", "http://localhost:8080");
    private static final HttpClient HTTP = HttpClient.newHttpClient();

    @Test
    void flujoCompletoDeCreacionEdicionYEliminacionDeItinerario() {
        login();
        loadAirportsAndVerifyMap();
        int sentBefore = countSentNotificationsForTestUser();
        createItinerary();
        verifyNotificationGenerated(sentBefore);
        String itineraryRowSelector = verifyItineraryAppearsInList();
        editItinerary(itineraryRowSelector);
        deleteItinerary();
    }

    private void login() {
        driver.get(BASE_URL + "/login");
        WebElement userNameInput = wait.until(ExpectedConditions.visibilityOfElementLocated(By.id("userName")));
        userNameInput.sendKeys(TEST_USER);
        capture("login");
        driver.findElement(By.cssSelector("form button[type='submit']")).click();

        wait.until(ExpectedConditions.urlContains("/dashboard"));
        settle(1500);
        capture("dashboard");
    }

    private void loadAirportsAndVerifyMap() {
        driver.findElement(By.linkText("Ver aeropuertos y mapa")).click();
        wait.until(ExpectedConditions.urlContains("/airports"));

        // El mapa Plotly solo se renderiza cuando hay al menos un aeropuerto
        // sincronizado; si la base está vacía, esta prueba lo sincroniza
        // implícitamente al crear el itinerario más abajo. Aquí solo se
        // verifica que la pantalla (y su contenedor de mapa) cargó sin error.
        wait.until(ExpectedConditions.presenceOfElementLocated(By.cssSelector("h1")));
        assertTrue(driver.findElement(By.cssSelector("h1")).getText().contains("Aeropuertos"));
        // Plotly se descarga de forma diferida: contra AWS tarda mas que en local, se espera a que pinte.
        new WebDriverWait(driver, Duration.ofSeconds(30)).until(
                ExpectedConditions.presenceOfElementLocated(By.cssSelector(".js-plotly-plot .main-svg")));
        settle(1500);
        capture("aeropuertos-y-mapa");
    }

    private void createItinerary() {
        driver.get(BASE_URL + "/itineraries/new");

        WebElement departureInput = wait.until(
                ExpectedConditions.visibilityOfElementLocated(By.id("departureAirportId")));
        departureInput.sendKeys(DEPARTURE_IATA);
        driver.findElement(By.id("arrivalAirportId")).sendKeys(ARRIVAL_IATA);

        String travelDate = java.time.LocalDate.now().plusDays(10).toString(); // yyyy-MM-dd
        // input type=date: sendKeys depende del locale de Chrome (dd/mm/aaaa en es); se asigna
        // el valor ISO y se dispara "input" para que el formulario reactivo de Angular lo lea.
        ((JavascriptExecutor) driver).executeScript(
                "arguments[0].value = arguments[1]; arguments[0].dispatchEvent(new Event('input', {bubbles: true}));",
                driver.findElement(By.id("travelDate")), travelDate);

        WebElement durationInput = driver.findElement(By.id("durationMinutes"));
        durationInput.clear();
        durationInput.sendKeys("90");
        settle(800);
        capture("formulario-nuevo-itinerario");

        driver.findElement(By.cssSelector("form button[type='submit']")).click();

        // La validación de aeropuertos (sección 14) ocurre en el backend al
        // enviar el formulario. Si el código IATA no existiera, el
        // errorInterceptor mostraría el banner global; su ausencia confirma
        // que la validación pasó.
        wait.until(ExpectedConditions.urlMatches("/itineraries$")); // lista, no /new ni /edit
        assertFalse(isErrorBannerVisible(), "No debería aparecer el banner de error tras crear el itinerario");
    }

    private String verifyItineraryAppearsInList() {
        driver.get(BASE_URL + "/itineraries");
        String rowSelector = String.format(
                "//tr[td[text()='%s'] and td[text()='%s']]", DEPARTURE_IATA, ARRIVAL_IATA);

        wait.until(ExpectedConditions.presenceOfElementLocated(By.xpath(rowSelector)));
        settle(800);
        capture("itinerario-creado-en-la-lista");
        return rowSelector;
    }

    private void editItinerary(String rowSelector) {
        WebElement row = driver.findElement(By.xpath(rowSelector));
        row.findElement(By.linkText("Editar")).click();

        WebElement durationInput = wait.until(
                ExpectedConditions.visibilityOfElementLocated(By.id("durationMinutes")));
        // El formulario se rellena con un GET asincrono: editar antes lo sobrescribe (visto contra AWS).
        wait.until(ExpectedConditions.attributeToBe(durationInput, "value", "90"));
        durationInput.clear();
        durationInput.sendKeys("120");
        settle(500);
        capture("edicion-duracion-120");

        driver.findElement(By.cssSelector("form button[type='submit']")).click();
        wait.until(ExpectedConditions.urlMatches("/itineraries$")); // lista, no /new ni /edit

        String updatedRowSelector = String.format(
                "//tr[td[text()='%s'] and td[text()='%s'] and td[text()='120']]",
                DEPARTURE_IATA, ARRIVAL_IATA);
        wait.until(ExpectedConditions.presenceOfElementLocated(By.xpath(updatedRowSelector)));
        settle(500);
        capture("itinerario-editado");
    }

    private void deleteItinerary() {
        String updatedRowSelector = "//tr[td[text()='" + DEPARTURE_IATA + "'] and td[text()='"
                + ARRIVAL_IATA + "'] and td[text()='120']]";

        WebElement row = driver.findElement(By.xpath(updatedRowSelector));
        row.findElement(By.cssSelector("button")).click(); // botón "Eliminar"

        wait.until(ExpectedConditions.alertIsPresent());
        driver.switchTo().alert().accept();

        wait.until(ExpectedConditions.invisibilityOfElementLocated(By.xpath(updatedRowSelector)));
        settle(800);
        capture("itinerario-eliminado");
    }

    /** Espera (Outbox poll + RabbitMQ) a que aparezca una notificacion SENT nueva para el usuario de prueba. */
    private void verifyNotificationGenerated(int sentBefore) {
        Instant deadline = Instant.now().plus(Duration.ofSeconds(30));
        while (Instant.now().isBefore(deadline)) {
            if (countSentNotificationsForTestUser() > sentBefore) {
                return;
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        fail("No se genero la notificacion del itinerario en 30 s (Outbox -> RabbitMQ -> Notification)");
    }

    // shortcut: cuenta por texto en vez de parsear JSON; basta mientras userName sea unico del test.
    private int countSentNotificationsForTestUser() {
        try {
            HttpResponse<String> response = HTTP.send(
                    HttpRequest.newBuilder(URI.create(GATEWAY_URL + "/api/notifications")).GET().build(),
                    HttpResponse.BodyHandlers.ofString());
            assertEquals(200, response.statusCode(), "GET /api/notifications via Gateway");
            Matcher m = Pattern.compile("\\{[^{}]*\"userName\":\"" + Pattern.quote(TEST_USER)
                    + "\"[^{}]*\"status\":\"SENT\"[^{}]*}").matcher(response.body());
            int count = 0;
            while (m.find()) {
                count++;
            }
            return count;
        } catch (IOException | InterruptedException ex) {
            throw new IllegalStateException("No se pudo consultar el historial de notificaciones", ex);
        }
    }

    private boolean isErrorBannerVisible() {
        return !driver.findElements(By.cssSelector(".error-banner")).isEmpty();
    }
}
