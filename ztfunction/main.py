import logging

from azure.functions import HttpRequest, HttpResponse

# HttpRequest documentation:
# https://learn.microsoft.com/en-us/python/api/azure-functions/azure.functions.http.httprequest?view=azure-python
def main(req: HttpRequest) -> HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')
    logging.info(f"Verb: {req.method}")
    logging.info(f"Path: {req.url}")
    logging.info(f"Authorization Header: {req.headers.get('Authorization')}")
    if req.method == "POST":
        logging.info(f"Request Body: {req.get_json()}")


    name = req.params.get('name')
    if not name:
        try:
            req_body = req.get_json()
        except ValueError:
            pass
        else:
            name = req_body.get('name')

    # name = "DarkWing Duck"
    if name:
        return HttpResponse(f"Well Hello there, {name}. This HTTP triggered function executed successfully.")
    else:
        return HttpResponse(
            "This HTTP triggered function executed successfully. Pass a name in the query string or in the request body for a personalized response.",
            status_code=200
        )
