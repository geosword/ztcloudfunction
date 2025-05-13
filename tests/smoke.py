import json
import pytest
from azure.functions import HttpRequest, HttpResponse
from ztfunction.main import main


def test_main_function_with_name():
    """
    Test the main function with a JSON payload containing a name.
    Verifies that the function returns a personalized response.
    """
    # Create a mock HTTP request with JSON payload
    payload = {
        "name": "dylan"
    }

    # Create a mock request object
    mock_request = HttpRequest(
        method="POST",
        url="/api/ztfunction",
        headers={},
        body=json.dumps(payload).encode('utf-8')
    )

    # Call the main function with our mock request
    response = main(mock_request)

    # Assert response is of correct type
    assert isinstance(response, HttpResponse)

    # Assert status code is 200
    assert response.status_code == 200

    # Assert the response contains the name from the payload
    assert "Well Hello there, dylan" in response.get_body().decode()
    assert "This HTTP triggered function executed successfully" in response.get_body().decode()


if __name__ == "__main__":
    pytest.main(["-v", "unittests.py"])
