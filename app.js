const form = document.querySelector("#greet-form");
const nameInput = document.querySelector("#name");
const greeting = document.querySelector("#greeting");
const status = document.querySelector("#status");

function greet(name) {
  const trimmed = name.trim();
  greeting.textContent = trimmed ? `Hello, ${trimmed}` : "Hello, World";
  status.textContent = trimmed
    ? `Greeting updated at ${new Date().toLocaleTimeString()}.`
    : "Showing the default greeting.";
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  greet(nameInput.value);
});

greet("");
