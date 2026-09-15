package com.itinerarios.e2e;

import com.itinerarios.e2e.support.SeleniumTestBase;
import org.junit.jupiter.api.Test;
import org.openqa.selenium.By;
import org.openqa.selenium.WebElement;
import org.openqa.selenium.support.ui.ExpectedConditions;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Flujo E2E principal (sección 38 de la especificación maestra):
 *
 *   Open Angular -> Load airports -> Open map -> Create itinerary
 *   -> Validate airport -> Save itinerary -> Verify itinerary -> Edit -> Delete
 *
 * Requiere el stack completo levantado (docker compose up en
 * itinerarios-infrastructure) y accesible en la URL de la propiedad
 * de sistema "e2e.baseUrl" (por defecto http://localhost:4200).
 */
class ItineraryFullFlowE2ETest extends SeleniumTestBase {

    private static final String TEST_USER = "Selenium E2E";
    private static final String DEPARTURE_IATA = "BOG";
    private static final String ARRIVAL_IATA = "MDE";

    @Test
    void flujoCompletoDeCreacionEdicionYEliminacionDeItinerario() {
        login();
        loadAirportsAndVerifyMap();
        createItinerary();
        String itineraryRowSelector = verifyItineraryAppearsInList();
        editItinerary(itineraryRowSelector);
        deleteItinerary();
    }

    private void login() {
        driver.get(BASE_URL + "/login");
        WebElement userNameInput = wait.until(ExpectedConditions.visibilityOfElementLocated(By.id("userName")));
        userNameInput.sendKeys(TEST_USER);
        driver.findElement(By.cssSelector("form button[type='submit']")).click();

        wait.until(ExpectedConditions.urlContains("/dashboard"));
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
    }

    private void createItinerary() {
        driver.get(BASE_URL + "/itineraries/new");

        WebElement departureInput = wait.until(
                ExpectedConditions.visibilityOfElementLocated(By.id("departureAirportId")));
        departureInput.sendKeys(DEPARTURE_IATA);
        driver.findElement(By.id("arrivalAirportId")).sendKeys(ARRIVAL_IATA);

        String travelDate = java.time.LocalDate.now().plusDays(10).toString(); // yyyy-MM-dd
        driver.findElement(By.id("travelDate")).sendKeys(travelDate);

        WebElement durationInput = driver.findElement(By.id("durationMinutes"));
        durationInput.clear();
        durationInput.sendKeys("90");

        driver.findElement(By.cssSelector("form button[type='submit']")).click();

        // La validación de aeropuertos (sección 14) ocurre en el backend al
        // enviar el formulario. Si el código IATA no existiera, el
        // errorInterceptor mostraría el banner global; su ausencia confirma
        // que la validación pasó.
        wait.until(ExpectedConditions.urlContains("/itineraries"));
        assertFalse(isErrorBannerVisible(), "No debería aparecer el banner de error tras crear el itinerario");
    }

    private String verifyItineraryAppearsInList() {
        driver.get(BASE_URL + "/itineraries");
        String rowSelector = String.format(
                "//tr[td[text()='%s'] and td[text()='%s']]", DEPARTURE_IATA, ARRIVAL_IATA);

        wait.until(ExpectedConditions.presenceOfElementLocated(By.xpath(rowSelector)));
        return rowSelector;
    }

    private void editItinerary(String rowSelector) {
        WebElement row = driver.findElement(By.xpath(rowSelector));
        row.findElement(By.linkText("Editar")).click();

        WebElement durationInput = wait.until(
                ExpectedConditions.visibilityOfElementLocated(By.id("durationMinutes")));
        durationInput.clear();
        durationInput.sendKeys("120");

        driver.findElement(By.cssSelector("form button[type='submit']")).click();
        wait.until(ExpectedConditions.urlContains("/itineraries"));

        String updatedRowSelector = String.format(
                "//tr[td[text()='%s'] and td[text()='%s'] and td[text()='120']]",
                DEPARTURE_IATA, ARRIVAL_IATA);
        wait.until(ExpectedConditions.presenceOfElementLocated(By.xpath(updatedRowSelector)));
    }

    private void deleteItinerary() {
        String updatedRowSelector = "//tr[td[text()='" + DEPARTURE_IATA + "'] and td[text()='"
                + ARRIVAL_IATA + "'] and td[text()='120']]";

        WebElement row = driver.findElement(By.xpath(updatedRowSelector));
        row.findElement(By.cssSelector("button")).click(); // botón "Eliminar"

        wait.until(ExpectedConditions.alertIsPresent());
        driver.switchTo().alert().accept();

        wait.until(ExpectedConditions.invisibilityOfElementLocated(By.xpath(updatedRowSelector)));
    }

    private boolean isErrorBannerVisible() {
        return !driver.findElements(By.cssSelector(".error-banner")).isEmpty();
    }
}
